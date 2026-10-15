import Foundation

public struct ServerBuild: Sendable {
    public let source: URL
    public let swift: String

    public init(source: URL, swift: String) {
        self.source = source
        self.swift = swift
    }

    /// Produces an environment-independent artifact. The caller owns its final storage.
    /// Callers must serialize builds sharing a checkout and avoid editing it during a build.
    public func build(ref: String, output: URL, log: URL) throws -> BuildArtifact {
        let fm = FileManager.default
        func git(_ arguments: [String]) throws -> String {
            try run("/usr/bin/git", arguments, directory: source, code: "source_failed")
        }
        func requireClean() throws {
            guard try git(["status", "--porcelain", "--untracked-files=normal"]).isEmpty else {
                throw BuildError("dirty_source", "Commit or remove local changes before building.")
            }
        }
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), ref.count <= 256 else {
            throw BuildError("invalid_ref", "Invalid Git ref.")
        }
        guard !fm.fileExists(atPath: output.path) else {
            throw BuildError("output_exists", "Build output must be a new directory.")
        }
        let root = try git(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path else {
            throw BuildError("invalid_source", "Source must be the repository root.")
        }
        try requireClean()
        let prefix = "refs/remotes/origin/"
        if ref.hasPrefix(prefix) {
            try run("/usr/bin/git", ["check-ref-format", ref], directory: source, code: "invalid_ref")
            let branch = String(ref.dropFirst(prefix.count))
            // Fetch the requested branch even when origin's configured fetch refspec excludes it.
            try run("/usr/bin/git", ["fetch", "origin", "+refs/heads/\(branch):\(ref)"],
                    directory: source, log: log, code: "fetch_failed")
        } else {
            try run("/usr/bin/git", ["fetch", "origin"], directory: source, log: log, code: "fetch_failed")
        }
        let commit = try run("/usr/bin/git", ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"],
                                    directory: source, code: "ref_resolution_failed")
        try run("/usr/bin/git", ["checkout", "--detach", commit], directory: source, log: log, code: "checkout_failed")
        try requireClean()

        let package = source.appendingPathComponent("Packages/WhubPackage")
        try run(swift, ["build", "--package-path", package.path, "-c", "release", "--product", "whub-server"],
                       log: log, code: "build_failed")
        // Detect edits or checkout changes during the build instead of assigning a misleading commit.
        try requireClean()
        guard try git(["rev-parse", "HEAD"]) == commit else {
            throw BuildError("source_changed", "The checkout changed while building.")
        }
        let bin = try run(swift, ["build", "--package-path", package.path, "-c", "release", "--show-bin-path"],
                                 code: "build_failed")
        let artifact = BuildArtifact(commit: commit)
        let staging = output.deletingLastPathComponent().appendingPathComponent(".building-\(artifact.id)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            let executable = URL(fileURLWithPath: bin).appendingPathComponent("whub-server")
            guard fm.isExecutableFile(atPath: executable.path) else {
                throw BuildError("artifact_failed", "The built server executable is missing or not executable.")
            }
            try fm.copyItem(at: executable, to: staging.appendingPathComponent("whub-server"))
            for resource in try fm.contentsOfDirectory(at: URL(fileURLWithPath: bin), includingPropertiesForKeys: nil)
                where resource.pathExtension == "resources" || resource.pathExtension == "bundle" {
                try fm.copyItem(at: resource, to: staging.appendingPathComponent(resource.lastPathComponent))
            }
            try JSONEncoder().encode(artifact).write(to: staging.appendingPathComponent("build.json"), options: .atomic)
            try fm.moveItem(at: staging, to: output)
        } catch {
            throw BuildError("artifact_failed", "Cannot assemble build artifact: \(error)")
        }
        return artifact
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
             log: URL? = nil, code: String = "command_failed") throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Avoid shell startup assumptions and injected Git/Swift configuration variables.
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME": inherited["HOME"] ?? "", "USER": inherited["USER"] ?? "",
                           "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"]
        for key in ["SSH_AUTH_SOCK", "SWIFTLY_HOME_DIR", "SWIFTLY_BIN_DIR", "LD_LIBRARY_PATH"] {
            environment[key] = inherited[key]
        }
        process.environment = environment
        var handle: FileHandle?
        let pipe = Pipe()
        if let log {
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try FileHandle(forWritingTo: log)
            try handle?.seekToEnd()
            try handle?.write(contentsOf: Data(("\n\(executable) \(arguments.joined(separator: " "))\n").utf8))
            process.standardOutput = handle; process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = FileHandle.standardError
        }
        defer { try? handle?.close() }
        do { try process.run() } catch { throw BuildError(code, "Could not start \(executable): \(error)") }
        let output = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = log == nil ? "" : " See the build log."
            throw BuildError(code, "\(executable) exited with status \(process.terminationStatus).\(detail)")
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct BuildArtifact: Codable, Sendable, Equatable {
    public let id: String
    public let commit: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, commit: String, createdAt: Date = Date()) {
        self.id = id
        self.commit = commit
        self.createdAt = createdAt
    }
}

public struct BuildError: Error, Codable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
