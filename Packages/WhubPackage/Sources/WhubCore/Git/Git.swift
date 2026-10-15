import Foundation

public enum GitChange: Sendable, Equatable {
    case added
    case modified
    case deleted
}

public enum GitError: LocalizedError {
    case notRepository
    case commandFailed(Int32)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .notRepository: "The directory is not in a Git repository."
        case let .commandFailed(status): "Git exited with status \(status)."
        case .invalidOutput: "Git returned invalid status output."
        }
    }
}

public enum Git {
    public static func needsStatusRefresh(
        changedPaths: [String], worktreeRoots: [String], managementDirectories: Set<URL>
    ) -> Bool {
        changedPaths.contains { path in
            if worktreeRoots.contains(where: { path == $0 + "/.git" }) { return true }
            if managementDirectories.isEmpty,
               worktreeRoots.contains(where: { path.hasPrefix($0 + "/.git/") }) { return true }
            return managementDirectories.contains { directory in
                let root = directory.path
                if path == root || root.hasPrefix(path + "/") { return true }
                guard path.hasPrefix(root + "/") else { return false }
                let name = path.dropFirst(root.count + 1).split(separator: "/").first ?? ""
                return ["HEAD", "index", "commondir", "config", "config.worktree",
                        "refs", "packed-refs", "reftable", "info"].contains(String(name))
                    || name.hasPrefix("sharedindex.")
            }
        }
    }

    public static func managementDirectories(at directory: URL) async throws -> Set<URL> {
        try await Task.detached(priority: .utility) {
            var directories: Set<URL> = []
            for option in ["--git-dir", "--git-common-dir"] {
                let output = try run(["rev-parse", "--path-format=absolute", option], at: directory)
                guard output.status == 0 else {
                    if directories.isEmpty { throw GitError.notRepository }
                    throw GitError.commandFailed(output.status)
                }
                guard var path = String(data: output.data, encoding: .utf8), path.hasSuffix("\n") else {
                    throw GitError.invalidOutput
                }
                path.removeLast()
                guard !path.isEmpty else { throw GitError.invalidOutput }
                directories.insert(URL(fileURLWithPath: path))
            }
            return directories
        }.value
    }

    public static func changes(at directory: URL) async throws -> [URL: GitChange] {
        try await Task.detached(priority: .utility) {
            let rootOutput = try run(["rev-parse", "--show-toplevel"], at: directory)
            guard rootOutput.status == 0 else { throw GitError.notRepository }
            guard var root = String(data: rootOutput.data, encoding: .utf8), root.hasSuffix("\n") else {
                throw GitError.invalidOutput
            }
            root.removeLast()
            let rootURL = URL(fileURLWithPath: root)

            let output = try run(
                ["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."],
                at: directory
            )
            guard output.status == 0 else { throw GitError.commandFailed(output.status) }
            return try parse(output.data, rootURL: rootURL)
        }.value
    }

    static func run(_ arguments: [String], at directory: URL) throws -> (data: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    private static func parse(_ data: Data, rootURL: URL) throws -> [URL: GitChange] {
        let entries = data.split(separator: 0).map { Array($0) }
        var changes: [URL: GitChange] = [:]
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count >= 4, entry[2] == 32,
                  let path = String(bytes: entry.dropFirst(3), encoding: .utf8), !path.isEmpty else {
                throw GitError.invalidOutput
            }
            let x = entry[0]
            let y = entry[1]
            let renamed = x == 82 || y == 82
            let copied = x == 67 || y == 67
            let change: GitChange = if x == 68 || y == 68 {
                .deleted
            } else if x == 65 || y == 65 || x == 63 || copied {
                .added
            } else {
                .modified
            }
            changes[rootURL.appendingPathComponent(path).standardizedFileURL] = change
            index += 1
            if renamed || copied {
                guard index < entries.count,
                      let oldPath = String(bytes: entries[index], encoding: .utf8), !oldPath.isEmpty else {
                    throw GitError.invalidOutput
                }
                if renamed {
                    changes[rootURL.appendingPathComponent(oldPath).standardizedFileURL] = .deleted
                }
                index += 1
            }
        }
        return changes
    }
}
