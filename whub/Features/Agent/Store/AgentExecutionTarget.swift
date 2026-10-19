import Foundation
import WhubAgent
import WhubClient
import WhubCore

@MainActor
enum AgentExecutionTarget {
    case local(host: LocalHost?, runtime: AgentRuntime)
    case remote(host: RemoteHost, servers: RemoteServerStore)

    var host: WhubCore.Host? {
        switch self {
        case .local(let host, _): host
        case .remote(let host, _): host
        }
    }

    var systemImage: String {
        switch self {
        case .local: "laptopcomputer"
        case .remote: "server.rack"
        }
    }

    var keepsExecutionOnDisconnect: Bool {
        switch self {
        case .local: false
        case .remote: true
        }
    }

    var disconnectMessage: String {
        switch self {
        case .local: "実行中の作業がある場合は中断されます。"
        case .remote: "このタブを閉じても、リモートでの作業は継続します。"
        }
    }

    func create(kind: AgentKind, directory: String, resuming entry: AgentHistoryEntry?) async throws -> UUID {
        switch self {
        case .local(_, let runtime): return try await runtime.create(kind: kind, directory: directory).id
        case .remote(let host, let servers):
            let api = try await servers.client(for: host).agent
            if let entry, let existing = try await api.list().first(where: {
                $0.kind == kind && $0.conversationID == entry.id && !$0.isClosed
            }) {
                return existing.id
            }
            return try await api.create(kind: kind, directory: directory).id
        }
    }

    func snapshot(sessionID: UUID) async throws -> (AgentSessionState, AgentSessionConnection?) {
        switch self {
        case .local(_, let runtime): return (try runtime.state(sessionID: sessionID), nil)
        case .remote(let host, let servers):
            let connection = try await servers.client(for: host).agent.connect(sessionID: sessionID)
            return (try await connection.state(), connection)
        }
    }

    func changes(sessionID: UUID, after revision: UInt64, connection: AgentSessionConnection?) async throws -> AgentSessionState {
        switch self {
        case .local(_, let runtime): return try await runtime.changes(sessionID: sessionID, after: revision)
        case .remote:
            guard let connection else { throw WhubClientError.connectionClosed }
            return try await connection.update()
        }
    }

    func execute(sessionID: UUID, command: AgentCommand) async throws -> AgentCommandReceipt {
        switch self {
        case .local(_, let runtime): try runtime.execute(sessionID: sessionID, command: command)
        case .remote(let host, let servers): try await servers.client(for: host).agent.execute(sessionID: sessionID, command: command)
        }
    }

    func models(sessionID: UUID) async throws -> [AgentModelOption] {
        switch self {
        case .local(_, let runtime): try await runtime.models(sessionID: sessionID)
        case .remote(let host, let servers): try await servers.client(for: host).agent.models(sessionID: sessionID)
        }
    }

    func skills(sessionID: UUID) async throws -> [AgentSkill] {
        switch self {
        case .local(_, let runtime): try await runtime.skills(sessionID: sessionID)
        case .remote(let host, let servers): try await servers.client(for: host).agent.skills(sessionID: sessionID)
        }
    }

    func status(sessionID: UUID) async throws -> [WhubAgent.AgentContent] {
        switch self {
        case .local(_, let runtime): try await runtime.status(sessionID: sessionID)
        case .remote(let host, let servers): try await servers.client(for: host).agent.status(sessionID: sessionID)
        }
    }

    func history(sessionID: UUID, cursor: String?) async throws -> AgentHistoryPage {
        switch self {
        case .local(_, let runtime): try await runtime.history(sessionID: sessionID, cursor: cursor)
        case .remote(let host, let servers): try await servers.client(for: host).agent.history(sessionID: sessionID, cursor: cursor)
        }
    }

    func disconnect(sessionID: UUID, connection: AgentSessionConnection?) {
        switch self {
        case .local(_, let runtime): try? runtime.close(sessionID: sessionID)
        case .remote:
            Task { try? await connection?.disconnect() }
        }
    }
}
