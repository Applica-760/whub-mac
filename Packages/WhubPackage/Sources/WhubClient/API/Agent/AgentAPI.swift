import Foundation
import WhubAgent

public struct AgentAPI: Sendable {
    let client: WhubClient

    public func create(kind: AgentKind, directory: String) async throws -> AgentSessionState {
        let body = try encode(AgentSessionConfiguration(kind: kind, directory: directory))
        let data = try await client.request("agent/sessions", method: "POST", body: body, expectedStatus: 201)
        return try client.decode(AgentSessionState.self, from: data)
    }

    public func list() async throws -> [AgentSessionState] {
        try await read([AgentSessionState].self, "agent/sessions")
    }

    public func state(sessionID: UUID) async throws -> AgentSessionState {
        try await read(AgentSessionState.self, path(sessionID))
    }

    /// Returns a newer snapshot, or the current snapshot after the server's bounded wait.
    public func changes(sessionID: UUID, after revision: UInt64) async throws -> AgentSessionState {
        try await read(AgentSessionState.self, path(sessionID) + "/changes",
                       query: [URLQueryItem(name: "after", value: String(revision))])
    }

    public func execute(sessionID: UUID, command: AgentCommand) async throws -> AgentCommandReceipt {
        let data = try await client.request(path(sessionID) + "/commands", method: "POST",
                                            body: encode(command), expectedStatus: 202)
        return try client.decode(AgentCommandReceipt.self, from: data)
    }

    public func models(sessionID: UUID) async throws -> [AgentModelOption] {
        try await read([AgentModelOption].self, path(sessionID) + "/models")
    }

    public func skills(sessionID: UUID) async throws -> [AgentSkill] {
        try await read([AgentSkill].self, path(sessionID) + "/skills")
    }

    public func status(sessionID: UUID) async throws -> [AgentContent] {
        try await read([AgentContent].self, path(sessionID) + "/status")
    }

    public func history(sessionID: UUID, cursor: String? = nil) async throws -> AgentHistoryPage {
        try await read(AgentHistoryPage.self, path(sessionID) + "/history",
                       query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }

    /// Explicitly terminates the session. Do not call when the HTTP/SSH connection is lost.
    public func close(sessionID: UUID) async throws {
        _ = try await client.request(path(sessionID), method: "DELETE", expectedStatus: 204)
    }

    private func path(_ id: UUID) -> String { "agent/sessions/\(id.uuidString)" }

    private func read<Value: Decodable>(_ type: Value.Type, _ path: String,
                                         query: [URLQueryItem] = []) async throws -> Value {
        let data = try await client.request(path, query: query)
        return try client.decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
}
