import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum ServerEnvironment: String, Codable, Sendable {
    case dev, prod
}

enum ServerOperation: String, Codable, Sendable {
    case update, fetch, build, apply, restart
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
    var operation: ServerOperation?
    var commit: String?
}

struct ManagerConfiguration: Codable, Sendable {
    let environment: ServerEnvironment
    let source: URL
    let swift: String
    let service: String
    let healthURL: URL
}

struct UpdateRequest: Codable {
    let configuration: ManagerConfiguration
    let ref: String
    var operation: ServerOperation?
    var buildID: String?
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

struct ServerOperationStore: Sendable {
    let root: URL

    var isLocked: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("update.lock").path) }
    var hasWorker: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("update.lock/worker").path) }

    func create(configuration: ManagerConfiguration, ref: String, operation: ServerOperation,
                validate: () throws -> BuildArtifact?) throws -> ServerUpdate {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = root.appendingPathComponent("update.lock")
        guard mkdir(lock.path, 0o700) == 0 else {
            throw ReleaseError("update_locked", "Another update or interrupted update may exist.")
        }
        do {
            let target = try validate()
            var update = ServerUpdate(id: UUID().uuidString, environment: configuration.environment,
                                      ref: ref, startedAt: Date(), status: "queued")
            update.operation = operation
            update.targetBuild = target?.id
            update.commit = target?.commit
            let directory = try updateDirectory(update.id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(UpdateRequest(configuration: configuration, ref: ref,
                                                    operation: operation, buildID: target?.id))
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

    func claim(id: String) throws -> (ServerUpdate, UpdateRequest) {
        let directory = try updateDirectory(id)
        let update = try readUpdate(id: id)
        let lock = root.appendingPathComponent("update.lock")
        guard (try? String(contentsOf: lock.appendingPathComponent("id"), encoding: .utf8)) == update.id,
              update.status == "queued", mkdir(lock.appendingPathComponent("worker").path, 0o700) == 0 else {
            throw ReleaseError("update_locked", "Update has no matching reservation or already started.")
        }
        let request = try JSONDecoder().decode(UpdateRequest.self, from: Data(contentsOf: directory.appendingPathComponent("request.json")))
        guard request.configuration.environment == update.environment, request.ref == update.ref,
              (request.operation ?? .update) == (update.operation ?? .update) else {
            throw ReleaseError("invalid_request", "Saved request and update state do not match.")
        }
        return (update, request)
    }

    func active(environment: ServerEnvironment) throws -> ServerUpdate? {
        guard let id = try? String(contentsOf: root.appendingPathComponent("update.lock/id"), encoding: .utf8) else { return nil }
        let update = try readUpdate(id: id)
        return update.environment == environment ? update : nil
    }

    func saveCommits(_ commits: [ServerCommit], id: String) throws {
        try JSONEncoder().encode(commits).write(to: try updateDirectory(id).appendingPathComponent("commits.json"), options: .atomic)
    }

    func save(_ update: ServerUpdate) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(update).write(to: try updateDirectory(update.id).appendingPathComponent("state.json"), options: .atomic)
    }

    func releaseLock(id: String) throws {
        let lock = root.appendingPathComponent("update.lock")
        guard try String(contentsOf: lock.appendingPathComponent("id"), encoding: .utf8) == id else {
            throw ReleaseError("update_locked", "Reservation ownership changed.")
        }
        try FileManager.default.removeItem(at: lock)
    }

    func updateDirectory(_ id: String) throws -> URL {
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

    func history(environment: ServerEnvironment? = nil) throws -> [ServerUpdate] {
        let updates = root.appendingPathComponent("updates")
        guard FileManager.default.fileExists(atPath: updates.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: updates, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("state.json").path) }
            .map { try readUpdate(id: $0.lastPathComponent) }
            .filter { environment == nil || $0.environment == environment }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func commits(environment: ServerEnvironment) throws -> [ServerCommit] {
        guard environment == .dev else { throw ReleaseError("invalid_request", "Commit selection is dev-only.") }
        guard let update = try history(environment: environment).last(where: { $0.operation == .fetch && $0.status == "succeeded" }) else {
            return []
        }
        return try JSONDecoder().decode([ServerCommit].self,
            from: Data(contentsOf: try updateDirectory(update.id).appendingPathComponent("commits.json")))
    }

}
