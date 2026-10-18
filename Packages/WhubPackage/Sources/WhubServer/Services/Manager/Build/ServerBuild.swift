import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct ServerBuild: Sendable {
    public let source: URL
    public let swift: String

    public init(source: URL, swift: String) {
        self.source = source
        self.swift = swift
    }

    /// Fetches all origin branches without changing HEAD or working files.
    /// The caller must serialize this with builds sharing the checkout.
    public func fetch(log: URL) throws -> [ServerCommit] {
        try requireSource()
        try run("/usr/bin/git", ["fetch", "--prune", "origin", "+refs/heads/*:refs/remotes/origin/*"],
                directory: source, log: log, code: "fetch_failed")
        return try commits()
    }

    /// Returns up to 100 distinct commits reachable from fetched origin branches.
    public func commits() throws -> [ServerCommit] {
        try requireSource()
        let output = try git(["log", "--remotes=origin", "--date-order", "--max-count=100", "--format=%H%x00%s%x00%ct"])
        return try output.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3, let timestamp = TimeInterval(fields[2]) else {
                throw BuildError("source_failed", "Invalid Git commit information.")
            }
            return ServerCommit(id: String(fields[0]), summary: String(fields[1]),
                                committedAt: Date(timeIntervalSince1970: timestamp))
        }
    }

    /// Produces an environment-independent artifact. The caller owns its final storage.
    /// Callers must serialize builds sharing a checkout and avoid editing it during a build.
    public func build(ref: String, output: URL, log: URL) throws -> BuildArtifact {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), ref.count <= 256 else {
            throw BuildError("invalid_ref", "Invalid Git ref.")
        }
        try requireNewOutput(output)
        try requireSource()
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
        return try build(commit: commit, output: output, log: log)
    }

    /// Builds the exact, already available commit without fetching or applying it.
    /// Callers must serialize builds sharing a checkout and avoid editing it during a build.
    public func build(commit: String, output: URL, log: URL) throws -> BuildArtifact {
        try Self.validateCommit(commit)
        try requireNewOutput(output)
        try requireSource()
        try requireClean()
        let resolved = try run("/usr/bin/git", ["rev-parse", "--verify", "--end-of-options", "\(commit)^{commit}"],
                               directory: source, code: "ref_resolution_failed")
        guard resolved == commit.lowercased() else {
            throw BuildError("invalid_commit", "The specified object is not a commit.")
        }
        let commit = resolved
        let fm = FileManager.default
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

    private func git(_ arguments: [String]) throws -> String {
        try run("/usr/bin/git", arguments, directory: source, code: "source_failed")
    }

    static func validateCommit(_ commit: String) throws {
        guard [40, 64].contains(commit.count),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw BuildError("invalid_commit", "Specify a full Git commit ID.")
        }
    }

    private func requireSource() throws {
        let root = try git(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path else {
            throw BuildError("invalid_source", "Source must be the repository root.")
        }
    }

    private func requireClean() throws {
        guard try git(["status", "--porcelain", "--untracked-files=normal"]).isEmpty else {
            throw BuildError("dirty_source", "Commit or remove local changes before building.")
        }
    }

    private func requireNewOutput(_ output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BuildError("output_exists", "Build output must be a new directory.")
        }
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
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { throw BuildError("log_failed", "Could not open build log.") }
            handle = FileHandle(fileDescriptor: descriptor)
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

public struct ServerCommit: Codable, Sendable, Equatable {
    public let id: String
    public let summary: String
    public let committedAt: Date
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
