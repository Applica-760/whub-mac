import Foundation
import Hummingbird

struct ManagerAPI: Sendable {
    let manager: ServerManager
    let configuration: ManagerConfiguration
    let token: String
    let executable: URL
    // Capture at startup: current may already point to another build during an update.
    let running: BuildArtifact?

    enum Action: Sendable {
        case start(ServerOperation)
        case history, update(String), log(String), status, commits, builds
    }

    func handle(_ request: Request, action: Action) async -> Response {
        do {
            guard hasValidBearerToken(request.headers[.authorization]) else { throw ManagerAPIError.unauthorized }
            switch action {
            case .log: break
            default:
                guard request.uri.query == nil else { throw ManagerAPIError.invalidRequest }
            }
            switch action {
            case .start(let operation):
                return try await acceptOperation(request, operation: operation)
            case .commits:
                return try makeJSONResponse(try await Task.detached { try manager.commits(environment: configuration.environment) }.value)
            case .builds:
                return try makeJSONResponse(try await Task.detached { try manager.builds(environment: configuration.environment) }.value)
            case .history:
                let updates = try await Task.detached {
                    try manager.history(environment: configuration.environment)
                }.value
                return try makeJSONResponse(updates)
            case .update(let id):
                let update = try await Task.detached { try manager.readUpdate(id: id, environment: configuration.environment) }.value
                return try makeJSONResponse(update)
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
                    try manager.log(id: id, environment: configuration.environment, offset: offset)
                }.value
                return try makeJSONResponse(log)
            case .status:
                let status = try await Task.detached {
                    try manager.status(environment: configuration.environment, running: running)
                }.value
                return try makeJSONResponse(status)
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

    private func acceptOperation(_ request: Request, operation: ServerOperation) async throws -> Response {
        let allowedFields: Set<String>
        switch operation {
        case .update: allowedFields = ["ref"]
        case .fetch, .restart: allowedFields = []
        case .build: allowedFields = ["commit"]
        case .apply: allowedFields = ["buildID"]
        }
        let fields = try await readValidatedJSONFields(request, allowedFields: allowedFields)
        let update = try await Task.detached {
            try manager.start(configuration: configuration, ref: fields["ref"] ?? fields["commit"],
                               executable: executable, operation: operation, buildID: fields["buildID"])
        }.value
        var response = try makeJSONResponse(update, status: .accepted)
        response.headers[.location] = "/manager/updates/\(update.id)"
        return response
    }

    private func readValidatedJSONFields(_ request: Request, allowedFields: Set<String>) async throws -> [String: String] {
        guard request.headers[.contentType]?.split(separator: ";").first?.lowercased() == "application/json" else {
            throw ManagerAPIError.invalidRequest
        }
        do {
            let buffer = try await request.body.collect(upTo: 4096)
            guard let values = try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: String],
                  Set(values.keys).isSubset(of: allowedFields) else { throw ManagerAPIError.invalidRequest }
            return values
        } catch { throw ManagerAPIError.invalidRequest }
    }

    private func hasValidBearerToken(_ header: String?) -> Bool {
        guard !token.isEmpty, let header, header.hasPrefix("Bearer ") else { return false }
        let supplied = Array(header.dropFirst(7).utf8)
        let expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= supplied[index] ^ expected[index] }
        return difference == 0
    }

    private func makeJSONResponse<Value: Encodable>(_ value: Value, status: HTTPResponse.Status = .ok) throws -> Response {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        guard data.count <= 8 * 1_048_576 else { throw ManagerAPIError.responseTooLarge }
        return Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                        body: .init(byteBuffer: .init(bytes: data)))
    }
}
