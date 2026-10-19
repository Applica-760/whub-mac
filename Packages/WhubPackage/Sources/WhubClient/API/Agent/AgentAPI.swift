import Foundation
import WhubAgent

public struct AgentAPI: Sendable {
    let client: WhubClient
    // Status can await three 60-second agent RPCs in sequence.
    private static let operationTimeout: TimeInterval = 210

    public func create(kind: AgentKind, directory: String) async throws -> AgentSessionSummary {
        let body = try encode(AgentSessionConfiguration(kind: kind, directory: directory))
        let data = try await client.request("agent/sessions", method: "POST", body: body, expectedStatus: 201, timeout: Self.operationTimeout)
        return try client.decode(AgentSessionSummary.self, from: data)
    }

    public func list() async throws -> [AgentSessionSummary] {
        try await read([AgentSessionSummary].self, "agent/sessions")
    }

    public func state(sessionID: UUID) async throws -> AgentSessionSummary {
        try await read(AgentSessionSummary.self, path(sessionID))
    }

    /// Creates a retrieval cache owned by one tab. No background polling or disk persistence.
    public func connect(sessionID: UUID) async throws -> AgentSessionConnection {
        let connection = AgentSessionConnection(api: self, sessionID: sessionID)
        _ = try await connection.update()
        return connection
    }

    public func openSnapshot(sessionID: UUID) async throws -> AgentSnapshot {
        let data = try await client.request(path(sessionID) + "/snapshots", method: "POST", expectedStatus: 201)
        return try client.decode(AgentSnapshot.self, from: data)
    }

    public func snapshotPage(sessionID: UUID, snapshotID: UUID, cursor: Int = 0) async throws -> AgentTransferPage {
        try await read(AgentTransferPage.self, path(sessionID) + "/snapshots/\(snapshotID)", query: position(cursor))
    }

    /// Nil means the server's bounded wait ended without a change (204).
    public func changes(sessionID: UUID, snapshotID: UUID, after revision: UInt64,
                        cursor: Int = 0) async throws -> AgentTransferPage? {
        let query = [URLQueryItem(name: "snapshot", value: snapshotID.uuidString),
                     URLQueryItem(name: "after", value: String(revision))] + position(cursor)
        let response = try await client.response(path(sessionID) + "/changes", query: query, expectedStatuses: [200, 204])
        if response.status == 204 { return nil }
        return try client.decode(AgentTransferPage.self, from: response.data)
    }

    public func imagePage(sessionID: UUID, imageID: UUID, cursor: Int = 0) async throws -> AgentImagePage {
        try await read(AgentImagePage.self, path(sessionID) + "/images/\(imageID)", query: position(cursor))
    }

    /// Idempotent release of retrieval data; never terminates the remote session.
    public func releaseSnapshot(sessionID: UUID, snapshotID: UUID) async throws {
        do {
            _ = try await client.request(path(sessionID) + "/snapshots/\(snapshotID)", method: "DELETE", expectedStatus: 204)
        } catch WhubClientError.api(status: 410, code: "resyncRequired", message: _) {
            return
        } catch WhubClientError.api(status: 404, code: "notFound", message: _) {
            return
        }
    }

    public func execute(sessionID: UUID, command: AgentCommand) async throws -> AgentCommandReceipt {
        let data = try await client.request(path(sessionID) + "/commands", method: "POST",
                                            body: encode(command), expectedStatus: 202)
        return try client.decode(AgentCommandReceipt.self, from: data)
    }

    public func models(sessionID: UUID) async throws -> [AgentModelOption] {
        try await read([AgentModelOption].self, path(sessionID) + "/models", timeout: Self.operationTimeout)
    }

    public func skills(sessionID: UUID) async throws -> [AgentSkill] {
        try await read([AgentSkill].self, path(sessionID) + "/skills", timeout: Self.operationTimeout)
    }

    public func status(sessionID: UUID) async throws -> [AgentContent] {
        try await read([AgentContent].self, path(sessionID) + "/status", timeout: Self.operationTimeout)
    }

    public func history(sessionID: UUID, cursor: String? = nil) async throws -> AgentHistoryPage {
        try await read(AgentHistoryPage.self, path(sessionID) + "/history",
                       query: cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [], timeout: Self.operationTimeout)
    }

    /// Explicitly terminates the session. Do not call when the HTTP/SSH connection is lost.
    public func close(sessionID: UUID) async throws {
        _ = try await client.request(path(sessionID), method: "DELETE", expectedStatus: 204)
    }

    private func position(_ cursor: Int) -> [URLQueryItem] { [URLQueryItem(name: "cursor", value: String(cursor))] }

    private func path(_ id: UUID) -> String { "agent/sessions/\(id.uuidString)" }

    private func read<Value: Decodable>(_ type: Value.Type, _ path: String,
                                         query: [URLQueryItem] = [], timeout: TimeInterval = 10) async throws -> Value {
        let data = try await client.request(path, query: query, timeout: timeout)
        return try client.decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
}
