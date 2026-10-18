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

/// All callers sharing a checkout must use the same root. Only the worker runs perform().
public struct ServerReleases: Sendable {
    public let root: URL
    private var operations: ServerOperationStore { ServerOperationStore(root: root) }
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

    func start(configuration: ManagerConfiguration, ref: String?, executable: URL,
               operation: ServerOperation = .update, buildID: String? = nil) throws -> ServerUpdate {
        let update = try prepare(configuration: configuration, ref: ref, operation: operation, buildID: buildID)
        let directory = try operations.updateDirectory(update.id)
        let runner = directory.appendingPathComponent("runner")
        var launchAttempted = false
        do {
            try FileManager.default.copyItem(at: executable.resolvingSymlinksInPath(), to: runner)
            launchAttempted = true
            try launch(root, update.id, runner)
        } catch {
            // A systemd transport failure may happen after execution starts. Keep its reservation.
            if !operations.hasWorker {
                var failed = update
                failed.status = "launch_failed"
                failed.errorCode = "launch_failed"
                failed.error = String(describing: error)
                failed.finishedAt = Date()
                try operations.save(failed)
            }
            if !launchAttempted { try operations.releaseLock(id: update.id) }
            throw ReleaseError("launch_failed", "Could not start update \(update.id); inspect its state and log.")
        }
        return update
    }

    private func prepare(configuration: ManagerConfiguration, ref: String?,
                         operation: ServerOperation = .update, buildID: String? = nil) throws -> ServerUpdate {
        let service = configuration.service
        guard !service.isEmpty, !service.hasPrefix("-"),
              service.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) }) else {
            throw ReleaseError("invalid_service", "Specify a systemd user service name.")
        }
        let selectedRef: String
        switch operation {
        case .fetch:
            guard configuration.environment == .dev, ref == nil, buildID == nil else {
                throw ReleaseError("invalid_request", "Fetch requires the dev environment and no parameters.")
            }
            selectedRef = ""
        case .apply, .restart:
            guard ref == nil, operation == .apply || buildID == nil else {
                throw ReleaseError("invalid_request", "Unexpected operation parameters.")
            }
            selectedRef = ""
        case .build where configuration.environment == .dev:
            guard let ref else { throw ReleaseError("invalid_commit", "Dev build requires a full commit ID.") }
            try ServerBuild.validateCommit(ref)
            selectedRef = ref.lowercased()
        case .build:
            guard ref == nil else { throw ReleaseError("invalid_ref", "Prod automatically selects origin/main.") }
            selectedRef = "refs/remotes/origin/main"
        case .update where configuration.environment == .prod:
            guard ref == nil || ref == "refs/remotes/origin/main" else {
                throw ReleaseError("invalid_ref", "prod only accepts refs/remotes/origin/main.")
            }
            selectedRef = "refs/remotes/origin/main"
        case .update:
            guard let ref, !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), ref.count <= 256 else {
                throw ReleaseError("invalid_ref", "dev requires a valid ref.")
            }
            selectedRef = ref
        }
        guard operation == .apply || buildID == nil else {
            throw ReleaseError("invalid_request", "Build ID is only accepted for Apply.")
        }
        guard ["http", "https"].contains(configuration.healthURL.scheme), configuration.healthURL.host != nil else {
            throw ReleaseError("invalid_health_url", "Specify an HTTP health endpoint.")
        }
        return try operations.create(configuration: configuration, ref: selectedRef, operation: operation) {
            if operation == .apply {
                guard let buildID else { throw ReleaseError("invalid_id", "Apply requires a build ID.") }
                return try availableBuild(id: buildID, environment: configuration.environment)
            }
            if operation == .restart {
                guard try linkedRelease(root.appendingPathComponent("environments/\(configuration.environment.rawValue)/current")) != nil else {
                    throw ReleaseError("not_found", "No current server is available to restart.")
                }
            }
            return nil
        }
    }

    func perform(id: String) async throws -> ServerUpdate {
        let fm = FileManager.default
        let directory = try operations.updateDirectory(id)
        let (initial, request) = try operations.claim(id: id)
        var update = initial
        let configuration = request.configuration
        let build = ServerBuild(source: configuration.source, swift: configuration.swift)
        let service = configuration.service
        let healthURL = configuration.healthURL
        let selectedRef = request.ref
        let operation = request.operation ?? .update
        let log = directory.appendingPathComponent("build.log")
        let env = root.appendingPathComponent("environments/\(configuration.environment.rawValue)")
        let current = env.appendingPathComponent("current")
        let previous = env.appendingPathComponent("previous")
        func save() throws { try operations.save(update) }
        var old: URL?
        var switched = false
        do {
            old = try linkedRelease(current)
            update.previousBuild = old?.lastPathComponent
            update.activeBuild = update.previousBuild
            if operation == .fetch {
                update.status = "fetching"
                try save()
                let commits = try build.fetch(log: log)
                try operations.saveCommits(commits, id: id)
            } else {
                let destination: URL
                if operation == .restart {
                    guard let old else { throw ReleaseError("not_found", "No current server is available to restart.") }
                    destination = old
                    update.targetBuild = old.lastPathComponent
                } else if operation == .apply {
                    guard let id = request.buildID, id == update.targetBuild else {
                        throw ReleaseError("invalid_request", "Saved build ID does not match the operation.")
                    }
                    let artifact = try availableBuild(id: id, environment: configuration.environment)
                    guard artifact.commit == update.commit else { throw ReleaseError("invalid_build", "Build metadata changed.") }
                    destination = try artifactDirectory(artifact.id)
                } else {
                    update.status = "building"
                    try save()
                    let output = directory.appendingPathComponent("artifact")
                    let artifact = try operation == .build && configuration.environment == .dev
                        ? build.build(commit: selectedRef, output: output, log: log)
                        : build.build(ref: selectedRef, output: output, log: log)
                    destination = root.appendingPathComponent("releases/\(artifact.id)")
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: output, to: destination)
                    update.targetBuild = artifact.id
                    update.commit = artifact.commit
                }
                if operation != .build && !(operation == .apply && old?.path == destination.path) {
                    update.status = operation == .restart ? "restarting" : "switching"
                    try save()
                    if operation != .restart {
                        try fm.createDirectory(at: env, withIntermediateDirectories: true)
                        if let old { try replaceLink(previous, with: old) }
                        try replaceLink(current, with: destination)
                        switched = true
                    }
                    update.activeBuild = nil
                    try save()
                    try restart(service, log)
                    try await verify(service, healthURL, destination.appendingPathComponent("whub-server"))
                    update.activeBuild = destination.lastPathComponent
                }
            }
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
        try operations.releaseLock(id: update.id)
        try? fm.removeItem(at: directory.appendingPathComponent("runner"))
        return update
    }

    func readUpdate(id: String, environment: ServerEnvironment? = nil) throws -> ServerUpdate {
        try operations.readUpdate(id: id, environment: environment)
    }

    func log(id: String, environment: ServerEnvironment, offset: UInt64) throws -> UpdateLog {
        try operations.log(id: id, environment: environment, offset: offset)
    }

    func status(environment: ServerEnvironment, running: BuildArtifact?) throws -> ManagerStatus {
        let env = root.appendingPathComponent("environments/\(environment.rawValue)")
        let current = try linkedRelease(env.appendingPathComponent("current"))?.lastPathComponent
        let previous = try linkedRelease(env.appendingPathComponent("previous"))?.lastPathComponent
        return ManagerStatus(environment: environment, running: running, current: current, previous: previous,
                             update: try operations.active(environment: environment), locked: operations.isLocked)
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
        try operations.history(environment: environment)
    }

    func commits(environment: ServerEnvironment) throws -> [ServerCommit] {
        try operations.commits(environment: environment)
    }

    func builds(environment: ServerEnvironment) throws -> [BuildArtifact] {
        try history(environment: environment).reversed().compactMap { update in
            guard update.operation == .build, update.status == "succeeded", let id = update.targetBuild else { return nil }
            return try? validatedArtifact(id: id, update: update)
        }
    }

    private func availableBuild(id: String, environment: ServerEnvironment) throws -> BuildArtifact {
        guard let uuid = UUID(uuidString: id) else { throw ReleaseError("invalid_id", "Invalid build ID.") }
        guard let update = try history(environment: environment).first(where: {
            $0.operation == .build && $0.status == "succeeded" && $0.targetBuild == uuid.uuidString
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

    private func artifactDirectory(_ id: String) throws -> URL {
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
