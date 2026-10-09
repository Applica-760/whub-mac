import Foundation

public struct FileDiff: Sendable, Equatable {
    public enum UnsupportedReason: Sendable, Equatable {
        case binary
        case conflict
        case submodule
        case symbolicLink
        case fileType
    }

    public enum Content: Sendable, Equatable {
        case text(before: String, after: String)
        case unsupported(UnsupportedReason)
    }

    public let fileURL: URL
    public let relativePath: String
    public let change: GitChange?
    public let content: Content
}

public extension Git {
    /// HEAD versus saved files, including untracked files; index-only differences are omitted.
    static func fileChanges(at directory: URL) async throws -> [URL: GitChange] {
        let candidates = try await changes(at: directory)
        return try await Task.detached(priority: .utility) {
            let repository = try FileDiffRepository(at: directory)
            var result: [URL: GitChange] = [:]
            for fileURL in candidates.keys {
                let diff = try repository.diff(at: fileURL)
                if let change = diff.change { result[fileURL] = change }
            }
            return result
        }.value
    }

    /// The directory must exist in the repository; the file and its parents may have been deleted.
    static func fileDiff(at fileURL: URL, in directory: URL) async throws -> FileDiff {
        try await Task.detached(priority: .utility) {
            try FileDiffRepository(at: directory).diff(at: fileURL)
        }.value
    }
}

private struct FileDiffRepository {
    struct Entry {
        let mode: String
        let object: String
    }

    let root: URL
    let head: [String: Entry]
    let submodules: Set<String>
    let conflicts: Set<String>

    init(at directory: URL) throws {
        let rootOutput = try Git.run(["rev-parse", "--show-toplevel"], at: directory)
        guard rootOutput.status == 0 else { throw GitError.notRepository }
        guard var path = String(data: rootOutput.data, encoding: .utf8), path.hasSuffix("\n") else {
            throw GitError.invalidOutput
        }
        path.removeLast()
        guard !path.isEmpty else { throw GitError.invalidOutput }
        root = URL(fileURLWithPath: path).standardizedFileURL

        let revision = try Git.run(["rev-parse", "--verify", "--quiet", "HEAD^{tree}"], at: root)
        if revision.status == 0 {
            guard let tree = String(data: revision.data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  !tree.isEmpty else { throw GitError.invalidOutput }
            head = try Self.records(Self.read(["ls-tree", "-r", "-z", tree], at: root)).reduce(into: [:]) {
                $0[$1.path] = Entry(mode: $1.fields[0], object: $1.fields[2])
            }
        } else {
            let branch = try Self.read(["symbolic-ref", "--quiet", "HEAD"], at: root)
            guard let ref = String(data: branch, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  !ref.isEmpty else { throw GitError.invalidOutput }
            let exists = try Git.run(["show-ref", "--verify", "--quiet", ref], at: root)
            guard exists.status == 1 else { throw GitError.commandFailed(revision.status) }
            head = [:]
        }

        let index = try Self.records(Self.read(["ls-files", "--stage", "-z"], at: root))
        submodules = Set(index.filter { $0.fields[0] == "160000" }.map(\.path))
        conflicts = Set(index.filter { $0.fields[2] != "0" }.map(\.path))
    }

    func diff(at fileURL: URL) throws -> FileDiff {
        let fileURL = fileURL.standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard fileURL.isFileURL, fileURL.path.hasPrefix(prefix), fileURL.path != root.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let path = String(fileURL.path.dropFirst(prefix.count))
        let original = head[path]
        func result(_ change: GitChange?, _ content: FileDiff.Content) -> FileDiff {
            FileDiff(fileURL: fileURL, relativePath: path, change: change, content: content)
        }
        if conflicts.contains(path) { return result(.modified, .unsupported(.conflict)) }
        if original?.mode == "160000" || submodules.contains(path) {
            let change: GitChange = original == nil ? .added
                : (FileManager.default.fileExists(atPath: fileURL.path) ? .modified : .deleted)
            return result(change, .unsupported(.submodule))
        }

        // Do not follow symlinks, including a replaced parent directory, while reading saved content.
        var current = root
        var attributes: [FileAttributeKey: Any]?
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component))
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                attributes = nil
                break
            }
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                return result(original == nil ? .added : .modified, .unsupported(.symbolicLink))
            }
            if current.path != fileURL.path, attributes?[.type] as? FileAttributeType != .typeDirectory {
                attributes = nil
                break
            }
        }
        let type = attributes?[.type] as? FileAttributeType
        let exists = type != nil && type != .typeDirectory
        let change: GitChange? = original == nil ? (exists ? .added : nil) : (exists ? .modified : .deleted)
        if original?.mode == "120000" { return result(change, .unsupported(.symbolicLink)) }
        if exists && type != .typeRegular { return result(change, .unsupported(.fileType)) }
        let before = try original.map { try Self.read(["cat-file", "blob", $0.object], at: root) }
        let after = try exists ? Data(contentsOf: fileURL) : nil
        let executable = ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        let modeChanged = original != nil && exists && (original?.mode == "100755") != executable
        let actualChange = before == after && !modeChanged ? nil : change
        let beforeData = before ?? Data()
        let afterData = after ?? Data()
        guard !beforeData.contains(0), !afterData.contains(0),
              String(data: beforeData, encoding: .utf8) != nil,
              String(data: afterData, encoding: .utf8) != nil else {
            return result(actualChange, .unsupported(.binary))
        }
        // String(data:encoding:) strips a UTF-8 BOM; preserve it after validating the encoding.
        return result(actualChange, .text(before: String(decoding: beforeData, as: UTF8.self),
                                          after: String(decoding: afterData, as: UTF8.self)))
    }

    private static func read(_ arguments: [String], at root: URL) throws -> Data {
        let output = try Git.run(arguments, at: root)
        guard output.status == 0 else { throw GitError.commandFailed(output.status) }
        return output.data
    }

    private static func records(_ data: Data) throws -> [(fields: [String], path: String)] {
        try data.split(separator: 0).map { record in
            guard let tab = record.firstIndex(of: 9),
                  let metadata = String(data: record[..<tab], encoding: .utf8),
                  let path = String(data: record[record.index(after: tab)...], encoding: .utf8),
                  !path.isEmpty else { throw GitError.invalidOutput }
            let fields = metadata.split(separator: " ").map(String.init)
            guard fields.count == 3 else { throw GitError.invalidOutput }
            return (fields, path)
        }
    }
}
