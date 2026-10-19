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
        case openSnapshot(String), snapshot(String, String), releaseSnapshot(String, String), image(String, String)
    }

    func handle(_ request: Request, action: Action) async throws -> Response {
        do {
            let allowed: Set<String>
            switch action {
            case .changes: allowed = ["snapshot", "after", "cursor"]
            case .snapshot, .image: allowed = ["cursor"]
            case .history: allowed = ["cursor"]
            default: allowed = []
            }
            let query = try parameters(request.uri.query, allowed: allowed)
            switch action {
            case .create:
                let configuration = try await body(AgentSessionConfiguration.self, request)
                let state = try await runtime.create(kind: configuration.kind, directory: configuration.directory)
                var response = try await json(runtime.summary(sessionID: state.id), status: .created)
                response.headers[.location] = "/agent/sessions/\(state.id)"
                return response
            case .list:
                return try await json(runtime.summaries())
            case .state(let id):
                return try await json(runtime.summary(sessionID: sessionID(id)))
            case .close(let id):
                try await runtime.close(sessionID: sessionID(id))
                return Response(status: .noContent, headers: [.cacheControl: "no-store"])
            case .changes(let id):
                guard let value = query["after"], !value.isEmpty,
                      value.allSatisfy({ $0.isASCII && $0.isNumber }), let revision = UInt64(value) else {
                    throw AgentAPIError.invalidRequest
                }
                guard let snapshot = query["snapshot"] else { throw AgentAPIError.invalidRequest }
                if let page = try await changes(sessionID: sessionID(id), snapshotID: sessionID(snapshot),
                                                after: revision, cursor: cursor(query)) {
                    return try json(page)
                }
                return Response(status: .noContent, headers: [.cacheControl: "no-store"])
            case .openSnapshot(let id):
                let snapshot = try await runtime.openSnapshot(sessionID: sessionID(id))
                var response = try json(snapshot, status: .created)
                response.headers[.location] = "/agent/sessions/\(id)/snapshots/\(snapshot.id)"
                return response
            case .snapshot(let id, let snapshot):
                return try await json(runtime.snapshotPage(sessionID: sessionID(id), snapshotID: sessionID(snapshot),
                                                          cursor: cursor(query)))
            case .releaseSnapshot(let id, let snapshot):
                try await runtime.releaseSnapshot(sessionID: sessionID(id), snapshotID: sessionID(snapshot))
                return Response(status: .noContent, headers: [.cacheControl: "no-store"])
            case .image(let id, let image):
                return try await json(runtime.imagePage(sessionID: sessionID(id), imageID: sessionID(image),
                                                       cursor: cursor(query)))
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

    private func changes(sessionID: UUID, snapshotID: UUID, after revision: UInt64,
                         cursor: Int) async throws -> AgentTransferPage? {
        if let page = try await runtime.changePage(sessionID: sessionID, snapshotID: snapshotID,
                                                   after: revision, cursor: cursor) { return page }
        // Only the HTTP observer is cancelled; accepted work remains owned by the runtime.
        return try await withThrowingTaskGroup(of: AgentTransferPage?.self) { group in
            group.addTask {
                _ = try await runtime.changes(sessionID: sessionID, after: revision)
                return try await runtime.changePage(sessionID: sessionID, snapshotID: snapshotID, after: revision)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return try await runtime.changePage(sessionID: sessionID, snapshotID: snapshotID, after: revision)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func cursor(_ query: [String: String]) throws -> Int {
        guard let value = query["cursor"] else { return 0 }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let cursor = Int(value) else {
            throw AgentAPIError.invalidRequest
        }
        return cursor
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
