import Foundation

public struct ManagerAPI: Sendable {
    public struct Update: Decodable, Sendable {
        public let id: String
        public let environment: String
        public let ref: String
        public let startedAt: Date
        public let finishedAt: Date?
        public let previousBuild: String?
        public let targetBuild: String?
        public let activeBuild: String?
        public let status: String
        public let error: String?
        public let errorCode: String?
        public let operation: String?
        public let commit: String?
    }

    public struct Status: Decodable, Sendable {
        public let environment: String
        public let running: Build?
        public let current: String?
        public let previous: String?
        public let update: Update?
        public let locked: Bool
    }

    public struct Commit: Decodable, Sendable {
        public let id: String
        public let summary: String
        public let committedAt: Date
    }

    public struct Build: Decodable, Sendable {
        public let id: String
        public let commit: String
        public let createdAt: Date
    }

    public struct Log: Decodable, Sendable {
        public let text: String
        public let nextOffset: UInt64
    }

    let client: WhubClient
    let token: String

    public func status() async throws -> Status {
        try await read(Status.self, "manager/status")
    }

    public func fetch() async throws -> Update {
        try await start("manager/fetch")
    }

    public func commits() async throws -> [Commit] {
        try await read([Commit].self, "manager/commits")
    }

    public func build(commit: String? = nil) async throws -> Update {
        try await start("manager/builds", fields: commit.map { ["commit": $0] } ?? [:])
    }

    public func builds() async throws -> [Build] {
        try await read([Build].self, "manager/builds")
    }

    public func apply(buildID: String) async throws -> Update {
        try await start("manager/apply", fields: ["buildID": buildID])
    }

    public func restart() async throws -> Update {
        try await start("manager/restart")
    }

    public func history() async throws -> [Update] {
        try await read([Update].self, "manager/updates")
    }

    public func update(id: String) async throws -> Update {
        try await read(Update.self, "manager/updates/\(id)")
    }

    public func log(id: String, offset: UInt64 = 0) async throws -> Log {
        try await read(Log.self, "manager/updates/\(id)/log", query: [URLQueryItem(name: "offset", value: String(offset))])
    }

    private func read<Value: Decodable>(_ type: Value.Type, _ path: String, query: [URLQueryItem] = []) async throws -> Value {
        let data = try await client.request(path, query: query, token: token)
        return try client.decode(type, from: data)
    }

    private func start(_ path: String, fields: [String: String] = [:]) async throws -> Update {
        let body = try JSONEncoder().encode(fields)
        let data = try await client.request(path, method: "POST", body: body, token: token, expectedStatus: 202)
        return try client.decode(Update.self, from: data)
    }
}
