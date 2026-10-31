import Foundation

public struct FilesAPI: Sendable {
    public struct FileEntry: Decodable, Sendable, Equatable {
        public enum Kind: String, Decodable, Sendable {
            case file, directory, symlink, other
        }

        public let name: String
        public let kind: Kind
    }

    let client: WhubClient

    public func listDirectory(root: String, path: String = "") async throws -> [FileEntry] {
        let data = try await client.request("files/list", query: query(root: root, path: path))
        return try client.decode([FileEntry].self, from: data)
    }

    public func readText(root: String, path: String) async throws -> String {
        guard !path.isEmpty else { throw WhubClientError.invalidPath }
        struct Reply: Decodable { let text: String }
        let data = try await client.request("files/read", query: query(root: root, path: path))
        return try client.decode(Reply.self, from: data).text
    }

    public func readImage(root: String, path: String) async throws -> Data {
        guard !path.isEmpty else { throw WhubClientError.invalidPath }
        return try await client.request("files/read-image", query: query(root: root, path: path))
    }

    public func writeText(root: String, path: String, expectedText: String, text: String) async throws -> String {
        guard !path.isEmpty else { throw WhubClientError.invalidPath }
        struct Reply: Decodable { let text: String }
        let body = try JSONEncoder().encode(["expectedText": expectedText, "text": text])
        let data = try await client.request("files/write", method: "PUT", query: query(root: root, path: path), body: body)
        return try client.decode(Reply.self, from: data).text
    }

    public func createFile(root: String, path: String) async throws {
        try await operate("create-file", root: root, path: path)
    }

    public func createDirectory(root: String, path: String) async throws {
        try await operate("create-directory", root: root, path: path)
    }

    public func rename(root: String, path: String, name: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        try await operate("rename", root: root, path: path, body: body)
    }

    public func move(root: String, path: String, directory: String) async throws {
        let body = try JSONEncoder().encode(["directory": directory])
        try await operate("move", root: root, path: path, body: body)
    }

    public func trash(root: String, path: String) async throws {
        try await operate("trash", root: root, path: path)
    }

    private func operate(_ endpoint: String, root: String, path: String, body: Data? = nil) async throws {
        guard !path.isEmpty else { throw WhubClientError.invalidPath }
        _ = try await client.request("files/\(endpoint)", method: "POST", query: query(root: root, path: path),
                                     body: body, expectedStatus: 204)
    }

    private func query(root: String, path: String) throws -> [URLQueryItem] {
        guard root.hasPrefix("/"), !path.hasPrefix("/"),
              !root.contains("\0"), !path.contains("\0"),
              !root.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains("..") else {
            throw WhubClientError.invalidPath
        }
        return [URLQueryItem(name: "root", value: root), URLQueryItem(name: "path", value: path)]
    }
}
