import Foundation
import Hummingbird

struct ManagerAPI: Sendable {
    let releases: ServerReleases
    let configuration: ManagerConfiguration
    let token: String
    let executable: URL
    // Capture at startup: current may already point to another build during an update.
    let running: BuildArtifact?

    enum Action: Sendable {
        case start, history, update(String), log(String), status
        case fetch, commits, build, builds, apply, restart
    }

    func handle(_ request: Request, action: Action) async -> Response {
        do {
            guard authorized(request.headers[.authorization]) else { throw ManagerAPIError.unauthorized }
            switch action {
            case .start, .fetch, .build, .apply, .restart:
                let operation: ServerOperation
                let allowed: Set<String>
                switch action {
                case .start: operation = .update; allowed = ["ref"]
                case .fetch: operation = .fetch; allowed = []
                case .build: operation = .build; allowed = ["commit"]
                case .apply: operation = .apply; allowed = ["buildID"]
                case .restart: operation = .restart; allowed = []
                default: throw ManagerAPIError.invalidRequest
                }
                let values = try await parameters(request, allowed: allowed)
                let update = try await Task.detached {
                    try releases.start(configuration: configuration, ref: values["ref"] ?? values["commit"],
                                       executable: executable, operation: operation, buildID: values["buildID"])
                }.value
                var response = try json(update, status: .accepted)
                response.headers[.location] = "/manager/updates/\(update.id)"
                return response
            case .commits:
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
                return try json(try await Task.detached { try releases.commits(environment: configuration.environment) }.value)
            case .builds:
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
                return try json(try await Task.detached { try releases.builds(environment: configuration.environment) }.value)
            case .history:
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
                let updates = try await Task.detached {
                    try releases.history(environment: configuration.environment)
                }.value
                return try json(updates)
            case .update(let id):
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
                let update = try await Task.detached { try releases.readUpdate(id: id, environment: configuration.environment) }.value
                return try json(update)
            case .log(let id):
                let offset: UInt64
                if let query = request.uri.query {
                    let pair = query.split(separator: "=", omittingEmptySubsequences: false)
                    guard pair.count == 2, pair[0] == "offset", !pair[1].isEmpty,
                          pair[1].allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(pair[1]) else {
                        throw ManagerAPIError.invalidRequest
                    }
                    offset = value
                } else { offset = 0 }
                let log = try await Task.detached {
                    try releases.log(id: id, environment: configuration.environment, offset: offset)
                }.value
                return try json(log)
            case .status:
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
                let status = try await Task.detached {
                    try releases.status(environment: configuration.environment, running: running)
                }.value
                return try json(status)
            }
        } catch let error as ManagerAPIError {
            return error.response
        } catch let error as ReleaseError {
            return ManagerAPIError(error).response
        } catch let error as BuildError {
            return ManagerAPIError(error).response
        } catch {
            return ManagerAPIError.operationFailed.response
        }
    }

    private func parameters(_ request: Request, allowed: Set<String>) async throws -> [String: String] {
        guard request.uri.query == nil,
              request.headers[.contentType]?.split(separator: ";").first?.lowercased() == "application/json" else {
            throw ManagerAPIError.invalidRequest
        }
        do {
            let buffer = try await request.body.collect(upTo: 4096)
            guard let values = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: String],
                  Set(values.keys).isSubset(of: allowed) else { throw ManagerAPIError.invalidRequest }
            return values
        } catch { throw ManagerAPIError.invalidRequest }
    }

    private func authorized(_ header: String?) -> Bool {
        guard !token.isEmpty, let header, header.hasPrefix("Bearer ") else { return false }
        let supplied = Array(header.dropFirst(7).utf8)
        let expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= supplied[index] ^ expected[index] }
        return difference == 0
    }

    private func json<Value: Encodable>(_ value: Value, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard data.count <= 8 * 1_048_576 else { throw ManagerAPIError.responseTooLarge }
        return Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }
}
