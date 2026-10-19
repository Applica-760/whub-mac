import Foundation
import Hummingbird
import WhubAgent

struct AgentAPI: Sendable {
    let runtime: AgentRuntime
    private static let maxBytes = 8 * 1_048_576

    enum Action: Sendable {
        case create, list
        case state(String), close(String), changes(String), execute(String)
        case models(String), skills(String), status(String), history(String)
    }

    func handle(_ request: Request, action: Action) async throws -> Response {
        do {
            let allowed: Set<String>
            switch action {
            case .changes: allowed = ["after"]
            case .history: allowed = ["cursor"]
            default: allowed = []
            }
            let query = try parameters(request.uri.query, allowed: allowed)
            switch action {
            case .create:
                let configuration = try await body(AgentSessionConfiguration.self, request)
                let state = try await runtime.create(kind: configuration.kind, directory: configuration.directory)
                var response = try json(state, status: .created)
                response.headers[.location] = "/agent/sessions/\(state.id)"
                return response
            case .list:
                return try await json(runtime.list())
            case .state(let id):
                return try await json(runtime.state(sessionID: sessionID(id)))
            case .close(let id):
                try await runtime.close(sessionID: sessionID(id))
                return Response(status: .noContent, headers: [.cacheControl: "no-store"])
            case .changes(let id):
                guard let value = query["after"], !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }), let revision = UInt64(value) else {
                    throw AgentAPIError.invalidRequest
                }
                return try await json(changes(sessionID: sessionID(id), after: revision))
            case .execute(let id):
                let id = try sessionID(id)
                let command = try await body(AgentCommand.self, request)
                return try await json(runtime.execute(sessionID: id, command: command), status: .accepted)
            case .models(let id):
                return try await json(runtime.models(sessionID: sessionID(id)))
            case .skills(let id):
                return try await json(runtime.skills(sessionID: sessionID(id)))
            case .status(let id):
                return try await json(runtime.status(sessionID: sessionID(id)))
            case .history(let id):
                return try await json(runtime.history(sessionID: sessionID(id), cursor: query["cursor"]))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AgentError {
            return try json(["error": error], status: AgentAPIError.status(for: error))
        } catch let error as AgentAPIError {
            return error.response
        } catch {
            return AgentAPIError.operationFailed.response
        }
    }

    private func changes(sessionID: UUID, after revision: UInt64) async throws -> AgentSessionState {
        // Bound the HTTP request; cancelling either observer never stops the runtime's execution.
        try await withThrowingTaskGroup(of: AgentSessionState.self) { group in
            group.addTask { try await runtime.changes(sessionID: sessionID, after: revision) }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return try await runtime.state(sessionID: sessionID)
            }
            defer { group.cancelAll() }
            guard let state = try await group.next() else { throw CancellationError() }
            return state
        }
    }

    private func sessionID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw AgentAPIError.invalidRequest }
        return id
    }

    private func parameters(_ query: String?, allowed: Set<String>) throws -> [String: String] {
        guard let query else { return [:] }
        guard query.utf8.count <= 4096 else { throw AgentAPIError.invalidRequest }
        var values: [String: String] = [:]
        for field in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let name = pair[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  allowed.contains(name), values[name] == nil, !value.isEmpty else {
                throw AgentAPIError.invalidRequest
            }
            values[name] = value
        }
        return values
    }

    private func body<Value: Decodable>(_ type: Value.Type, _ request: Request) async throws -> Value {
        guard request.headers[.contentType]?.split(separator: ";").first?.lowercased() == "application/json" else {
            throw AgentAPIError.invalidRequest
        }
        do {
            let buffer = try await request.body.collect(upTo: Self.maxBytes)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(type, from: Data(buffer.readableBytesView))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentAPIError.invalidRequest
        }
    }

    private func json<Value: Encodable>(_ value: Value, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard data.count <= Self.maxBytes else { throw AgentAPIError.responseTooLarge }
        return Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }
}
