import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// All callers sharing a checkout must use the same root. Only the worker runs perform().
public struct ServerManager: Sendable {
    public let root: URL
    private var operations: ServerOperationStore { ServerOperationStore(root: root) }
    private let releases: ServerReleases
    private let launch: @Sendable (URL, String, URL) throws -> Void

    public init(root: URL) {
        self.init(root: root, restart: ServerReleases.restartService, stop: ServerReleases.stopService,
                  verify: ServerReleases.verifyService)
    }

    init(root: URL, restart: @escaping @Sendable (String, URL) throws -> Void,
         stop: @escaping @Sendable (String, URL) throws -> Void = ServerReleases.stopService,
         verify: @escaping @Sendable (String, URL, URL) async throws -> Void,
         launch: @escaping @Sendable (URL, String, URL) throws -> Void = Self.launchUpdate) {
        self.root = root.standardizedFileURL
        self.releases = ServerReleases(root: self.root, restart: restart, stop: stop, verify: verify)
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
            try ServerSource.validateCommit(ref)
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
                return try releases.availableBuild(id: buildID, environment: configuration.environment,
                                                   history: operations.history(environment: configuration.environment))
            }
            if operation == .restart {
                guard try releases.current(environment: configuration.environment) != nil else {
                    throw ReleaseError("not_found", "No current server is available to restart.")
                }
            }
            return nil
        }
    }

    func perform(id: String) async throws -> ServerUpdate {
        let directory = try operations.updateDirectory(id)
        let (initial, request) = try operations.claim(id: id)
        var update = initial
        let configuration = request.configuration
        let source = ServerSource(source: configuration.source)
        let build = ServerBuild(source: configuration.source, swift: configuration.swift)
        let operation = request.operation ?? .update
        let log = directory.appendingPathComponent("build.log")
        func save(_ state: ServerUpdate) throws { try operations.save(state) }
        do {
            update.previousBuild = try releases.current(environment: configuration.environment)?.lastPathComponent
            update.activeBuild = update.previousBuild
            switch operation {
            case .fetch:
                update.status = "fetching"
                try save(update)
                try operations.saveCommits(source.fetch(log: log), id: id)
            case .build, .update:
                update.status = "building"
                try save(update)
                let output = directory.appendingPathComponent("artifact")
                let commit = try operation == .build && configuration.environment == .dev
                    ? request.ref : source.fetchCommit(ref: request.ref, log: log)
                let artifact = try build.build(commit: commit, output: output, log: log)
                let destination = try releases.store(artifact, from: output)
                update.targetBuild = artifact.id
                update.commit = artifact.commit
                if operation == .update {
                    await releases.activate(destination: destination, configuration: configuration,
                                            restartOnly: false, update: &update, log: log, save: save)
                }
            case .apply:
                guard let id = request.buildID, id == update.targetBuild else {
                    throw ReleaseError("invalid_request", "Saved build ID does not match the operation.")
                }
                let artifact = try releases.availableBuild(id: id, environment: configuration.environment,
                                                          history: operations.history(environment: configuration.environment))
                guard artifact.commit == update.commit else { throw ReleaseError("invalid_build", "Build metadata changed.") }
                let destination = try releases.artifactDirectory(artifact.id)
                await releases.activate(destination: destination, configuration: configuration,
                                        restartOnly: false, update: &update, log: log, save: save)
            case .restart:
                guard let destination = try releases.current(environment: configuration.environment) else {
                    throw ReleaseError("not_found", "No current server is available to restart.")
                }
                update.targetBuild = destination.lastPathComponent
                await releases.activate(destination: destination, configuration: configuration,
                                        restartOnly: true, update: &update, log: log, save: save)
            }
            if update.error == nil { update.status = "succeeded" }
        } catch {
            update.error = String(describing: error)
            update.errorCode = (error as? BuildError)?.code ?? (error as? ReleaseError)?.code ?? "update_failed"
            update.status = "failed"
        }
        update.finishedAt = Date()
        try save(update)
        try operations.releaseLock(id: update.id)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("runner"))
        return update
    }

    func readUpdate(id: String, environment: ServerEnvironment? = nil) throws -> ServerUpdate {
        try operations.readUpdate(id: id, environment: environment)
    }

    func log(id: String, environment: ServerEnvironment, offset: UInt64) throws -> UpdateLog {
        try operations.log(id: id, environment: environment, offset: offset)
    }

    func status(environment: ServerEnvironment, running: BuildArtifact?) throws -> ManagerStatus {
        let current = try releases.current(environment: environment)?.lastPathComponent
        let previous = try releases.previous(environment: environment)?.lastPathComponent
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
        try releases.builds(environment: environment, history: operations.history(environment: environment))
    }
}

// Git and Swift share command execution, logging, and the restricted environment.
enum ManagerCommand {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil,
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
