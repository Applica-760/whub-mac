import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WhubClientError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidPath
    case invalidResponse
    case responseTooLarge
    case connectionClosed, updateInProgress
    case api(status: Int, code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Server URL is invalid."
        case .invalidPath: "Root must be absolute and path must remain relative to it."
        case .invalidResponse: "Server returned an invalid response."
        case .connectionClosed: "Agent connection is closed."
        case .updateInProgress: "An agent update is already in progress."
        case .responseTooLarge: "Server response exceeds the 8 MiB limit."
        case let .api(_, _, message): message
        }
    }
}

public struct WhubClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    public var files: FilesAPI { FilesAPI(client: self) }

    public var manager: ManagerAPI { ManagerAPI(client: self) }

    public var agent: AgentAPI { AgentAPI(client: self) }

    public init(baseURL: URL, session: URLSession = .shared) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw WhubClientError.invalidURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    public func ping() async throws {
        let data = try await request("ping")
        guard data == Data("pong".utf8) else { throw WhubClientError.invalidResponse }
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                 body: Data? = nil, expectedStatus: Int = 200, timeout: TimeInterval = 10) async throws -> Data {
        try await response(path, method: method, query: query, body: body,
                           expectedStatuses: [expectedStatus], timeout: timeout).data
    }

    func response(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                  expectedStatuses: Set<Int> = [200], timeout: TimeInterval = 10) async throws -> (data: Data, status: Int) {
        try Task.checkCancellation()
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw WhubClientError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
            // The server decodes '+' as a space in query parameters.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw WhubClientError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw WhubClientError.invalidResponse }
        guard data.count <= 8 * 1_048_576 else { throw WhubClientError.responseTooLarge }
        guard expectedStatuses.contains(response.statusCode) else {
            struct Reply: Decodable {
                struct Detail: Decodable { let code: String; let message: String }
                let error: Detail
            }
            let reply = try decode(Reply.self, from: data)
            throw WhubClientError.api(status: response.statusCode, code: reply.error.code, message: reply.error.message)
        }
        return (data, response.statusCode)
    }

    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(type, from: data) }
        catch { throw WhubClientError.invalidResponse }
    }
}
