import Foundation

/// Zero-based, half-open line ranges; an empty range marks an insertion or deletion point.
public struct GitDiffHunk: Sendable, Equatable {
    public let oldLines: Range<Int>
    public let newLines: Range<Int>
}

public extension Git {
    static func diff(at fileURL: URL) async throws -> [GitDiffHunk] {
        try await Task.detached(priority: .utility) {
            let fileURL = fileURL.standardizedFileURL
            let directory = fileURL.deletingLastPathComponent()
            let repository = try run(["rev-parse", "--show-toplevel"], at: directory)
            guard repository.status == 0 else { throw GitError.notRepository }

            let pathspec = ":(literal)\(fileURL.lastPathComponent)"
            let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z", "--", pathspec], at: directory)
            guard untracked.status == 0 else { throw GitError.commandFailed(untracked.status) }
            if !untracked.data.isEmpty { return try allAddedLines(in: fileURL) }

            let head = try run(["rev-parse", "--verify", "HEAD"], at: directory)
            if head.status != 0 {
                let tracked = try run(["ls-files", "--cached", "-z", "--", pathspec], at: directory)
                guard tracked.status == 0 else { throw GitError.commandFailed(tracked.status) }
                if tracked.data.isEmpty { return [] }
                return try allAddedLines(in: fileURL)
            }

            let output = try run(
                ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--unified=0", "HEAD", "--", pathspec],
                at: directory
            )
            guard output.status == 0 else { throw GitError.commandFailed(output.status) }
            return try parseDiff(output.data)
        }.value
    }

    private static func allAddedLines(in fileURL: URL) throws -> [GitDiffHunk] {
        let data = try Data(contentsOf: fileURL)
        let lineCount = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (data.isEmpty || data.last == 10 ? 0 : 1)
        return lineCount == 0 ? [] : [GitDiffHunk(oldLines: 0..<0, newLines: 0..<lineCount)]
    }

    private static func parseDiff(_ data: Data) throws -> [GitDiffHunk] {
        let pattern = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var hunks: [GitDiffHunk] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("@@ ") {
            let header = String(line)
            guard let match = pattern.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
                throw GitError.invalidOutput
            }
            func number(_ group: Int, default defaultValue: Int) -> Int? {
                guard let range = Range(match.range(at: group), in: header) else { return defaultValue }
                return Int(header[range])
            }
            guard let oldStart = number(1, default: 0), let oldCount = number(2, default: 1),
                  let newStart = number(3, default: 0), let newCount = number(4, default: 1) else {
                throw GitError.invalidOutput
            }
            let oldLower = oldCount == 0 ? oldStart : oldStart - 1
            let newLower = newCount == 0 ? newStart : newStart - 1
            guard oldLower >= 0, newLower >= 0,
                  oldLower <= Int.max - oldCount, newLower <= Int.max - newCount else {
                throw GitError.invalidOutput
            }
            hunks.append(GitDiffHunk(
                oldLines: oldLower..<(oldLower + oldCount),
                newLines: newLower..<(newLower + newCount)
            ))
        }
        return hunks
    }
}
