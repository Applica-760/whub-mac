import Foundation
import WhubGit

struct GitService: Sendable {
    struct Change: Encodable {
        let path: String
        let change: String
    }

    struct Diff: Encodable {
        struct Content: Encodable {
            let type: String
            var before: String?
            var after: String?
            var reason: String?
        }

        let path: String
        let change: String?
        let content: Content

        enum CodingKeys: String, CodingKey { case path, change, content }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(change, forKey: .change)
            try container.encode(content, forKey: .content)
        }
    }

    func changes(root: String) async throws -> [Change] {
        _ = try FilesService(root: root)
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let changes = try await Git.fileChanges(at: rootURL)
        let prefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        return changes.compactMap { url, change -> Change? in
            guard url.path.hasPrefix(prefix) else { return nil }
            return Change(path: String(url.path.dropFirst(prefix.count)), change: Self.name(change))
        }.sorted { $0.path < $1.path }
    }

    func diff(root: String, path: String) async throws -> Diff {
        _ = try FilesService(root: root)
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let diff = try await Git.fileDiff(at: rootURL.appendingPathComponent(path), in: rootURL)
        let content: Diff.Content
        switch diff.content {
        case let .text(before, after):
            content = Diff.Content(type: "text", before: before, after: after)
        case let .unsupported(reason):
            let name: String
            switch reason {
            case .binary: name = "binary"
            case .conflict: name = "conflict"
            case .submodule: name = "submodule"
            case .symbolicLink: name = "symbolicLink"
            case .fileType: name = "fileType"
            }
            content = Diff.Content(type: "unsupported", reason: name)
        }
        return Diff(path: path, change: diff.change.map(Self.name), content: content)
    }

    private static func name(_ change: GitChange) -> String {
        switch change {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        }
    }
}
