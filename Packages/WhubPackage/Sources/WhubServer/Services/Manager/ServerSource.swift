import Foundation

public struct ServerSource: Sendable {
    public let source: URL

    public init(source: URL) { self.source = source }

    /// Fetches all origin branches without changing HEAD or working files.
    /// The caller must serialize this with builds sharing the checkout.
    public func fetch(log: URL) throws -> [ServerCommit] {
        try requireSource()
        try ManagerCommand.run("/usr/bin/git", ["fetch", "--prune", "origin", "+refs/heads/*:refs/remotes/origin/*"],
                directory: source, log: log, code: "fetch_failed")
        return try commits()
    }

    /// Returns up to 100 distinct commits reachable from fetched origin branches.
    public func commits() throws -> [ServerCommit] {
        try requireSource()
        let output = try git(["log", "--remotes=origin", "--date-order", "--max-count=100", "--format=%H%x00%s%x00%ct"])
        return try output.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3, let timestamp = TimeInterval(fields[2]) else {
                throw BuildError("source_failed", "Invalid Git commit information.")
            }
            return ServerCommit(id: String(fields[0]), summary: String(fields[1]),
                                committedAt: Date(timeIntervalSince1970: timestamp))
        }
    }

    /// Fetches and resolves a ref without changing the checkout.
    public func fetchCommit(ref: String, log: URL) throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), ref.count <= 256 else {
            throw BuildError("invalid_ref", "Invalid Git ref.")
        }
        try requireSource()
        try requireClean()
        let prefix = "refs/remotes/origin/"
        if ref.hasPrefix(prefix) {
            try ManagerCommand.run("/usr/bin/git", ["check-ref-format", ref], directory: source, code: "invalid_ref")
            let branch = String(ref.dropFirst(prefix.count))
            // Fetch the requested branch even when origin's configured fetch refspec excludes it.
            try ManagerCommand.run("/usr/bin/git", ["fetch", "origin", "+refs/heads/\(branch):\(ref)"],
                    directory: source, log: log, code: "fetch_failed")
        } else {
            try ManagerCommand.run("/usr/bin/git", ["fetch", "origin"], directory: source, log: log, code: "fetch_failed")
        }
        let commit = try ManagerCommand.run("/usr/bin/git", ["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"],
                                    directory: source, code: "ref_resolution_failed")
        return commit
    }

    func checkout(commit: String, log: URL) throws -> String {
        try Self.validateCommit(commit)
        try requireSource()
        try requireClean()
        let resolved = try ManagerCommand.run("/usr/bin/git", ["rev-parse", "--verify", "--end-of-options", "\(commit)^{commit}"],
                               directory: source, code: "ref_resolution_failed")
        guard resolved == commit.lowercased() else {
            throw BuildError("invalid_commit", "The specified object is not a commit.")
        }
        let commit = resolved
        try ManagerCommand.run("/usr/bin/git", ["checkout", "--detach", commit], directory: source, log: log, code: "checkout_failed")
        try requireClean()

        return commit
    }

    func verifyCheckout(commit: String) throws {
        try requireClean()
        guard try git(["rev-parse", "HEAD"]) == commit else {
            throw BuildError("source_changed", "The checkout changed while building.")
        }
    }

    private func git(_ arguments: [String]) throws -> String {
        try ManagerCommand.run("/usr/bin/git", arguments, directory: source, code: "source_failed")
    }

    static func validateCommit(_ commit: String) throws {
        guard [40, 64].contains(commit.count),
              commit.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw BuildError("invalid_commit", "Specify a full Git commit ID.")
        }
    }

    private func requireSource() throws {
        let root = try git(["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: root).resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path else {
            throw BuildError("invalid_source", "Source must be the repository root.")
        }
    }

    private func requireClean() throws {
        guard try git(["status", "--porcelain", "--untracked-files=normal"]).isEmpty else {
            throw BuildError("dirty_source", "Commit or remove local changes before building.")
        }
    }
}

public struct ServerCommit: Codable, Sendable, Equatable {
    public let id: String
    public let summary: String
    public let committedAt: Date
}
