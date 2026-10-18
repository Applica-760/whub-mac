import Foundation

public struct ServerBuild: Sendable {
    public let source: URL
    public let swift: String

    public init(source: URL, swift: String) {
        self.source = source
        self.swift = swift
    }

    /// Builds the exact, already available commit without fetching or applying it.
    /// Callers must serialize builds sharing a checkout and avoid editing it during a build.
    public func build(commit: String, output: URL, log: URL) throws -> BuildArtifact {
        try ServerSource.validateCommit(commit)
        try requireNewOutput(output)
        let checkout = ServerSource(source: source)
        let commit = try checkout.checkout(commit: commit, log: log)
        let fm = FileManager.default
        let package = source.appendingPathComponent("Packages/WhubPackage")
        try ManagerCommand.run(swift, ["build", "--package-path", package.path, "-c", "release", "--product", "whub-server"],
                       log: log, code: "build_failed")
        // Detect edits or checkout changes during the build instead of assigning a misleading commit.
        try checkout.verifyCheckout(commit: commit)
        let bin = try ManagerCommand.run(swift, ["build", "--package-path", package.path, "-c", "release", "--show-bin-path"],
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

    private func requireNewOutput(_ output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw BuildError("output_exists", "Build output must be a new directory.")
        }
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
