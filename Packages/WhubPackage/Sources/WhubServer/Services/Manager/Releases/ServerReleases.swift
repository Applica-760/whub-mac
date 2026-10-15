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
    public var errorCode: String?
}

public struct ReleaseError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

struct ManagerConfiguration: Codable, Sendable {
    let environment: ServerEnvironment
    let source: URL
    let swift: String
    let service: String
    let healthURL: URL
}

private struct UpdateRequest: Codable {
    let configuration: ManagerConfiguration
    let ref: String
}

struct ManagerStatus: Codable, Sendable {
    let environment: ServerEnvironment
    let running: BuildArtifact?
    let current: String?
    let previous: String?
    let update: ServerUpdate?
    let locked: Bool
}

struct UpdateLog: Codable, Sendable {
    let text: String
    let nextOffset: UInt64
}

/// All callers sharing a checkout must use the same root. Only the worker runs perform().
public struct ServerReleases: Sendable {
    public let root: URL
    private let restart: @Sendable (String, URL) throws -> Void
    private let stop: @Sendable (String, URL) throws -> Void
    private let verify: @Sendable (String, URL, URL) async throws -> Void
    private let launch: @Sendable (URL, String, URL) throws -> Void

    public init(root: URL) {
        self.init(root: root, restart: Self.restartService, stop: Self.stopService, verify: Self.verifyService)
    }

    init(root: URL, restart: @escaping @Sendable (String, URL) throws -> Void,
         stop: @escaping @Sendable (String, URL) throws -> Void = Self.stopService,
         verify: @escaping @Sendable (String, URL, URL) async throws -> Void,
         launch: @escaping @Sendable (URL, String, URL) throws -> Void = Self.launchUpdate) {
        self.root = root.standardizedFileURL
        self.restart = restart
        self.stop = stop
        self.verify = verify
        self.launch = launch
    }

    /// prod always builds the fetched origin/main; dev requires an explicit ref.
    public func release(environment: ServerEnvironment, ref: String? = nil, build: ServerBuild,
                        service: String, healthURL: URL) async throws -> ServerUpdate {
        let configuration = ManagerConfiguration(environment: environment, source: build.source, swift: build.swift,
                                                 service: service, healthURL: healthURL)
        let update = try prepare(configuration: configuration, ref: ref)
        return try await perform(id: update.id)
    }

    func start(configuration: ManagerConfiguration, ref: String?, executable: URL) throws -> ServerUpdate {
        let update = try prepare(configuration: configuration, ref: ref)
        let directory = try updateDirectory(update.id)
        let runner = directory.appendingPathComponent("runner")
        var launchAttempted = false
        do {
            try FileManager.default.copyItem(at: executable.resolvingSymlinksInPath(), to: runner)
            launchAttempted = true
            try launch(root, update.id, runner)
        } catch {
            // A systemd transport failure may happen after execution starts. Keep its reservation.
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("update.lock/worker").path) {
                var failed = update
                failed.status = "launch_failed"
                failed.errorCode = "launch_failed"
                failed.error = String(describing: error)
                failed.finishedAt = Date()
                try save(failed)
            }
            if !launchAttempted { try releaseLock(id: update.id) }
            throw ReleaseError("launch_failed", "Could not start update \(update.id); inspect its state and log.")
        }
        return update
    }

    private func prepare(configuration: ManagerConfiguration, ref: String?) throws -> ServerUpdate {
        let service = configuration.service
        guard !service.isEmpty, !service.hasPrefix("-"),
              service.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) }) else {
            throw ReleaseError("invalid_service", "Specify a systemd user service name.")
        }
        let selectedRef: String
        if configuration.environment == .prod {
            guard ref == nil || ref == "refs/remotes/origin/main" else {
                throw ReleaseError("invalid_ref", "prod only accepts refs/remotes/origin/main.")
            }
            selectedRef = "refs/remotes/origin/main"
        } else {
            guard let ref, !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), ref.count <= 256 else {
                throw ReleaseError("invalid_ref", "dev requires a valid ref.")
            }
            selectedRef = ref
        }
        guard ["http", "https"].contains(configuration.healthURL.scheme), configuration.healthURL.host != nil else {
            throw ReleaseError("invalid_health_url", "Specify an HTTP health endpoint.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = root.appendingPathComponent("update.lock")
        guard mkdir(lock.path, 0o700) == 0 else {
            throw ReleaseError("update_locked", "Another update or interrupted update may exist.")
        }
        do {
            let update = ServerUpdate(id: UUID().uuidString, environment: configuration.environment,
                                      ref: selectedRef, startedAt: Date(), status: "queued")
            let directory = try updateDirectory(update.id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(UpdateRequest(configuration: configuration, ref: selectedRef))
                .write(to: directory.appendingPathComponent("request.json"), options: .atomic)
            guard fm.createFile(atPath: directory.appendingPathComponent("build.log").path, contents: nil,
                                attributes: [.posixPermissions: 0o600]) else {
                throw ReleaseError("storage_failed", "Could not create update log.")
            }
            try save(update)
            try Data(update.id.utf8).write(to: lock.appendingPathComponent("id"), options: .atomic)
            return update
        } catch {
            try? fm.removeItem(at: lock)
            throw error
        }
    }

    func perform(id: String) async throws -> ServerUpdate {
        let fm = FileManager.default
        let directory = try updateDirectory(id)
        var update = try readUpdate(id: id)
        let lock = root.appendingPathComponent("update.lock")
        guard (try? String(contentsOf: lock.appendingPathComponent("id"), encoding: .utf8)) == update.id,
              update.status == "queued", mkdir(lock.appendingPathComponent("worker").path, 0o700) == 0 else {
            throw ReleaseError("update_locked", "Update has no matching reservation or already started.")
        }
        let request = try JSONDecoder().decode(UpdateRequest.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
        guard request.configuration.environment == update.environment, request.ref == update.ref else {
            throw ReleaseError("invalid_request", "Saved request and update state do not match.")
        }
        let configuration = request.configuration
        let build = ServerBuild(source: configuration.source, swift: configuration.swift)
        let service = configuration.service
        let healthURL = configuration.healthURL
        let selectedRef = request.ref
        let log = directory.appendingPathComponent("build.log")
        let env = root.appendingPathComponent("environments/\(configuration.environment.rawValue)")
        let current = env.appendingPathComponent("current")
        let previous = env.appendingPathComponent("previous")
        func save() throws { try self.save(update) }
        var old: URL?
        var switched = false
        do {
            update.status = "building"
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
            update.errorCode = (error as? BuildError)?.code ?? (error as? ReleaseError)?.code ?? "update_failed"
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
                    update.errorCode = "recovery_failed"
                    update.error = "\(update.error ?? ""); recovery: \(error)"
                }
            }
        }
        update.finishedAt = Date()
        try save()
        try releaseLock(id: update.id)
        try? fm.removeItem(at: directory.appendingPathComponent("runner"))
        return update
    }

    private func save(_ update: ServerUpdate) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(update).write(to: try updateDirectory(update.id).appendingPathComponent("state.json"), options: .atomic)
    }

    private func releaseLock(id: String) throws {
        let lock = root.appendingPathComponent("update.lock")
        guard try String(contentsOf: lock.appendingPathComponent("id"), encoding: .utf8) == id else {
            throw ReleaseError("update_locked", "Reservation ownership changed.")
        }
        try FileManager.default.removeItem(at: lock)
    }

    private func updateDirectory(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ReleaseError("invalid_id", "Invalid update ID.") }
        return root.appendingPathComponent("updates/\(uuid.uuidString)")
    }

    func readUpdate(id: String, environment: ServerEnvironment? = nil) throws -> ServerUpdate {
        let file = try updateDirectory(id).appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw ReleaseError("not_found", "Update not found.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let update = try decoder.decode(ServerUpdate.self, from: Data(contentsOf: file))
        guard environment == nil || update.environment == environment else { throw ReleaseError("not_found", "Update not found.") }
        return update
    }

    func log(id: String, environment: ServerEnvironment, offset: UInt64) throws -> UpdateLog {
        _ = try readUpdate(id: id, environment: environment)
        let handle = try FileHandle(forReadingFrom: updateDirectory(id).appendingPathComponent("build.log"))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard offset <= size else { throw ReleaseError("invalid_offset", "Offset exceeds log size.") }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        return UpdateLog(text: String(decoding: data, as: UTF8.self), nextOffset: offset + UInt64(data.count))
    }

    func status(environment: ServerEnvironment, running: BuildArtifact?) throws -> ManagerStatus {
        let env = root.appendingPathComponent("environments/\(environment.rawValue)")
        let current = try linkedRelease(env.appendingPathComponent("current"))?.lastPathComponent
        let previous = try linkedRelease(env.appendingPathComponent("previous"))?.lastPathComponent
        let lock = root.appendingPathComponent("update.lock")
        var update: ServerUpdate?
        if let id = try? String(contentsOf: lock.appendingPathComponent("id"), encoding: .utf8) {
            let active = try readUpdate(id: id)
            if active.environment == environment { update = active }
        }
        return ManagerStatus(environment: environment, running: running, current: current, previous: previous,
                             update: update, locked: FileManager.default.fileExists(atPath: lock.path))
    }

    private static func launchUpdate(root: URL, id: String, runner: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemd-run")
        var arguments = ["--user", "--collect", "--service-type=exec", "--expand-environment=no",
                         "--unit=whub-update-\(id)"]
        for key in ["SSH_AUTH_SOCK", "SWIFTLY_HOME_DIR", "SWIFTLY_BIN_DIR", "LD_LIBRARY_PATH"] {
            if let value = ProcessInfo.processInfo.environment[key] { arguments.append("--setenv=\(key)=\(value)") }
        }
        process.arguments = arguments + ["--", runner.path, "update", root.path, id]
        let descriptor = open(root.appendingPathComponent("updates/\(id)/build.log").path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else { throw ReleaseError("log_failed", "Could not open update log.") }
        let handle = FileHandle(fileDescriptor: descriptor)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReleaseError("launch_failed", "systemd-run failed: \(process.terminationStatus)") }
    }

    public func history(environment: ServerEnvironment? = nil) throws -> [ServerUpdate] {
        let updates = root.appendingPathComponent("updates")
        guard FileManager.default.fileExists(atPath: updates.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("state.json").path) }
            .map { try readUpdate(id: $0.lastPathComponent) }
            .filter { environment == nil || $0.environment == environment }
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
