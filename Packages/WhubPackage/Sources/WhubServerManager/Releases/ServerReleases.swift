import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum ServerEnvironment: String, Codable, Sendable {
    case dev, prod
}

public struct ServerUpdate: Codable, Sendable {
    public let id: String
    public let environment: ServerEnvironment
    public let ref: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var previousBuild: String?
    public var targetBuild: String?
    public var activeBuild: String?
    public var status: String
    public var error: String?
}

public struct ReleaseError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

/// Run outside the managed server process. All callers sharing a checkout must use the same root.
public struct ServerReleases: Sendable {
    public let root: URL
    private let restart: @Sendable (String, URL) throws -> Void
    private let stop: @Sendable (String, URL) throws -> Void
    private let verify: @Sendable (String, URL, URL) async throws -> Void

    public init(root: URL) {
        self.init(root: root, restart: Self.restartService, stop: Self.stopService, verify: Self.verifyService)
    }

    init(root: URL, restart: @escaping @Sendable (String, URL) throws -> Void,
         stop: @escaping @Sendable (String, URL) throws -> Void = Self.stopService,
         verify: @escaping @Sendable (String, URL, URL) async throws -> Void) {
        self.root = root.standardizedFileURL
        self.restart = restart
        self.stop = stop
        self.verify = verify
    }

    /// prod always builds the fetched origin/main; dev requires an explicit ref.
    public func release(environment: ServerEnvironment, ref: String? = nil, build: ServerBuild,
                        service: String, healthURL: URL) async throws -> ServerUpdate {
        guard !service.isEmpty, !service.hasPrefix("-"),
              service.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) }) else {
            throw ReleaseError("invalid_service", "Specify a systemd user service name.")
        }
        let selectedRef: String
        if environment == .prod {
            guard ref == nil || ref == "refs/remotes/origin/main" else {
                throw ReleaseError("invalid_ref", "prod only accepts refs/remotes/origin/main.")
            }
            selectedRef = "refs/remotes/origin/main"
        } else {
            guard let ref, !ref.isEmpty else { throw ReleaseError("invalid_ref", "dev requires a ref.") }
            selectedRef = ref
        }
        guard ["http", "https"].contains(healthURL.scheme), healthURL.host != nil else {
            throw ReleaseError("invalid_health_url", "Specify an HTTP health endpoint.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("update.lock")
        // Atomic mkdir also rejects other processes. A crash leaves the lock for manual recovery.
        guard mkdir(lock.path, 0o700) == 0 else {
            throw ReleaseError("update_locked", "Cannot acquire \(lock.path); another update or interrupted update may exist.")
        }
        defer { try? fm.removeItem(at: lock) }
        let directory = root.appendingPathComponent("updates/\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("build.log")
        let env = root.appendingPathComponent("environments/\(environment.rawValue)")
        let current = env.appendingPathComponent("current")
        let previous = env.appendingPathComponent("previous")
        var update = ServerUpdate(id: directory.lastPathComponent, environment: environment, ref: selectedRef,
                                  startedAt: Date(), status: "building")
        func save() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(update).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
        var old: URL?
        var switched = false
        do {
            old = try linkedRelease(current)
            update.previousBuild = old?.lastPathComponent
            update.activeBuild = update.previousBuild
            try save()
            let output = directory.appendingPathComponent("artifact")
            let artifact = try build.build(ref: selectedRef, output: output, log: log)
            let destination = root.appendingPathComponent("releases/\(artifact.id)")
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: output, to: destination)
            update.targetBuild = artifact.id
            update.status = "switching"
            try save()
            try fm.createDirectory(at: env, withIntermediateDirectories: true)
            if let old { try replaceLink(previous, with: old) }
            try replaceLink(current, with: destination)
            switched = true
            update.activeBuild = nil
            try save()
            try restart(service, log)
            try await verify(service, healthURL, destination.appendingPathComponent("whub-server"))
            update.activeBuild = artifact.id
            update.status = "succeeded"
        } catch {
            update.error = String(describing: error)
            update.status = "failed"
            if switched {
                update.status = "rolling_back"
                // Recovery must still run if persisting the intermediate status fails.
                try? save()
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
                    update.error = "\(update.error ?? ""); recovery: \(error)"
                }
            }
        }
        update.finishedAt = Date()
        try save()
        return update
    }

    public func history() throws -> [ServerUpdate] {
        let updates = root.appendingPathComponent("updates")
        guard FileManager.default.fileExists(atPath: updates.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)
            .map { try decoder.decode(ServerUpdate.self, from: Data(contentsOf: $0.appendingPathComponent("state.json"))) }
            .sorted { $0.startedAt < $1.startedAt }
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

    private static func restartService(_ service: String, _ log: URL) throws {
        try systemctl(["restart", service], log: log)
    }

    private static func stopService(_ service: String, _ log: URL) throws {
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
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try FileHandle(forWritingTo: log)
            try handle?.seekToEnd()
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

    private static func verifyService(_ service: String, _ healthURL: URL, _ executable: URL) async throws {
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
