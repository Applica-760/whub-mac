import Foundation

public struct DiffTree: Sendable, Equatable {
    public let url: URL
    /// The node's own change; inferred parent directories have no change.
    public let change: GitChange?
    public let children: [DiffTree]
}

public enum TreeDiff {
    public static func tree(for gitChanges: [URL: GitChange], under rootURL: URL) -> DiffTree {
        let root = rootURL.standardizedFileURL.path
        let prefix = root == "/" ? "/" : root + "/"
        var changes: [String: GitChange] = [:]
        var children: [String: Set<String>] = [:]
        for (url, change) in gitChanges {
            var path = url.standardizedFileURL.path
            guard path != root, path.hasPrefix(prefix) else { continue }
            changes[path] = change
            while path != root {
                let parent = (path as NSString).deletingLastPathComponent
                let inserted = children[parent, default: []].insert(path).inserted
                if !inserted { break }
                path = parent
            }
        }
        func node(at path: String) -> DiffTree {
            let nodes = children[path, default: []].sorted {
                let comparison = ($0 as NSString).lastPathComponent.localizedStandardCompare(
                    ($1 as NSString).lastPathComponent
                )
                return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
            }.map { node(at: $0) }
            return DiffTree(
                url: URL(fileURLWithPath: path, isDirectory: false),
                change: changes[path], children: nodes
            )
        }
        return node(at: root)
    }

    public static func changes(for gitChanges: [URL: GitChange], under rootURL: URL?) -> [URL: GitChange] {
        guard let rootURL else { return [:] }
        let root = rootURL.standardizedFileURL
        var result = gitChanges
        for (url, change) in gitChanges {
            var parent = url.deletingLastPathComponent()
            while parent == root || parent.path.hasPrefix(root.path + "/") {
                let current = result[parent]
                result[parent] = (current == nil || current == .added) && change == .added ? .added : .modified
                if parent == root { break }
                parent = parent.deletingLastPathComponent()
            }
        }
        return result
    }
}
