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
