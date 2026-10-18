import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct ReleaseError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

struct ServerReleases: Sendable {
    let root: URL
    private let restart: @Sendable (String, URL) throws -> Void
    private let stop: @Sendable (String, URL) throws -> Void
    private let verify: @Sendable (String, URL, URL) async throws -> Void

    init(root: URL, restart: @escaping @Sendable (String, URL) throws -> Void,
         stop: @escaping @Sendable (String, URL) throws -> Void,
         verify: @escaping @Sendable (String, URL, URL) async throws -> Void) {
        self.root = root
        self.restart = restart
        self.stop = stop
        self.verify = verify
    }

    func store(_ artifact: BuildArtifact, from output: URL) throws -> URL {
        let destination = root.appendingPathComponent("releases/\(artifact.id)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: output, to: destination)
        return destination
    }

    func current(environment: ServerEnvironment) throws -> URL? {
        try linkedRelease(root.appendingPathComponent("environments/\(environment.rawValue)/current"))
    }

    func previous(environment: ServerEnvironment) throws -> URL? {
        try linkedRelease(root.appendingPathComponent("environments/\(environment.rawValue)/previous"))
    }

    func activate(destination: URL, configuration: ManagerConfiguration, restartOnly: Bool,
                  update: inout ServerUpdate, log: URL, save: (ServerUpdate) throws -> Void) async {
        let fm = FileManager.default
        let service = configuration.service
        let healthURL = configuration.healthURL
        let env = root.appendingPathComponent("environments/\(configuration.environment.rawValue)")
        let current = env.appendingPathComponent("current")
        let previous = env.appendingPathComponent("previous")
        var old: URL?
        var switched = false
        do {
            old = try linkedRelease(current)
            if !restartOnly && old?.path == destination.path { return }
            update.status = restartOnly ? "restarting" : "switching"
            try save(update)
            if !restartOnly {
                try fm.createDirectory(at: env, withIntermediateDirectories: true)
                if let old { try replaceLink(previous, with: old) }
                try replaceLink(current, with: destination)
                switched = true
            }
            update.activeBuild = nil
            try save(update)
            try restart(service, log)
            try await verify(service, healthURL, destination.appendingPathComponent("whub-server"))
            update.activeBuild = destination.lastPathComponent
        } catch {
            update.error = String(describing: error)
            update.errorCode = (error as? BuildError)?.code ?? (error as? ReleaseError)?.code ?? "update_failed"
            update.status = "failed"
            if switched {
                update.status = "rolling_back"
                // Recovery must still run if persisting the intermediate status fails.
                try? save(update)
                do {
                    if let old {
                        try replaceLink(current, with: old)
                        try restart(service, log)
                        let verify = self.verify
                        try await Task.detached {
                            try await verify(service, healthURL, old.appendingPathComponent("whub-server"))
                        }.value
                        update.activeBuild = old.lastPathComponent
                        update.status = "rolled_back"
                    } else {
                        try fm.removeItem(at: current)
                        try stop(service, log)
                        update.activeBuild = nil
                        update.status = "failed"
                    }
                } catch {
                    update.activeBuild = nil
                    update.status = "recovery_failed"
                    update.errorCode = "recovery_failed"
                    update.error = "\(update.error ?? ""); recovery: \(error)"
                }
            }
        }
    }

    func builds(environment: ServerEnvironment, history: [ServerUpdate]) throws -> [BuildArtifact] {
        history.reversed().compactMap { update in
            guard update.environment == environment, update.operation == .build, update.status == "succeeded", let id = update.targetBuild else { return nil }
            return try? validatedArtifact(id: id, update: update)
        }
    }

    func availableBuild(id: String, environment: ServerEnvironment, history: [ServerUpdate]) throws -> BuildArtifact {
        guard let uuid = UUID(uuidString: id) else { throw ReleaseError("invalid_id", "Invalid build ID.") }
        guard let update = history.first(where: {
            $0.environment == environment && $0.operation == .build && $0.status == "succeeded" && $0.targetBuild == uuid.uuidString
        }) else {
            throw ReleaseError("not_found", "No successful build exists in this environment.")
        }
        return try validatedArtifact(id: uuid.uuidString, update: update)
    }

    private func validatedArtifact(id: String, update: ServerUpdate) throws -> BuildArtifact {
        let artifact = try readArtifact(id)
        guard artifact.commit == update.commit,
              update.environment != .prod || update.ref == "refs/remotes/origin/main" else {
            throw ReleaseError("invalid_build", "Build provenance does not match its metadata.")
        }
        return artifact
    }

    func artifactDirectory(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ReleaseError("invalid_id", "Invalid build ID.") }
        let releases = root.appendingPathComponent("releases").resolvingSymlinksInPath()
        let directory = releases.appendingPathComponent(uuid.uuidString).resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == releases,
              FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("whub-server").path) else {
            throw ReleaseError("invalid_build", "Build is outside releases or has no executable.")
        }
        return directory
    }

    private func readArtifact(_ id: String) throws -> BuildArtifact {
        let file = try artifactDirectory(id).appendingPathComponent("build.json")
        let artifact = try JSONDecoder().decode(BuildArtifact.self, from: Data(contentsOf: file))
        guard artifact.id == id else { throw ReleaseError("invalid_build", "Build ID does not match its metadata.") }
        return artifact
    }

    private func linkedRelease(_ link: URL) throws -> URL? {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: link.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            throw ReleaseError("invalid_current", "\(link.path) must be a release symlink.")
        }
        let destination = link.resolvingSymlinksInPath()
        let releases = root.appendingPathComponent("releases").resolvingSymlinksInPath()
        guard destination.deletingLastPathComponent().path == releases.path,
              fm.isExecutableFile(atPath: destination.appendingPathComponent("whub-server").path) else {
            throw ReleaseError("invalid_current", "Current release is outside releases or has no executable.")
        }
        return destination
    }

    private func replaceLink(_ link: URL, with destination: URL) throws {
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: destination)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, link.path) == 0 else {
            throw ReleaseError("link_failed", "Cannot replace \(link.path): errno \(errno)")
        }
    }

    static func restartService(_ service: String, _ log: URL) throws {
        try systemctl(["restart", service], log: log)
    }

    static func stopService(_ service: String, _ log: URL) throws {
        try systemctl(["stop", service], log: log)
    }

    @discardableResult
    private static func systemctl(_ arguments: [String], log: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemctl")
        process.arguments = ["--user"] + arguments
        let pipe = Pipe()
        var handle: FileHandle?
        if let log {
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { throw ReleaseError("log_failed", "Could not open service log.") }
            handle = FileHandle(fileDescriptor: descriptor)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
        }
        defer { try? handle?.close() }
        try process.run()
        let data = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReleaseError("service_failed", "systemctl \(arguments.joined(separator: " ")) failed: \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func verifyService(_ service: String, _ healthURL: URL, _ executable: URL) async throws {
        for _ in 0..<30 {
            try Task.checkCancellation()
            if let pid = try? systemctl(["show", service, "--property=MainPID", "--value"]),
               let number = Int(pid), number > 0,
               URL(fileURLWithPath: "/proc/\(number)/exe").resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path {
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 1
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   String(decoding: data, as: UTF8.self) == "pong" { return }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ReleaseError("health_failed", "Expected server executable and ping response were not confirmed.")
    }
}
