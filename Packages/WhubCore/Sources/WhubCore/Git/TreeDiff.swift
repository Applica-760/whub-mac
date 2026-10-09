import Foundation

public enum TreeDiff {
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
