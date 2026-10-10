import Foundation

/// Zero-based, half-open line ranges; an empty range marks an insertion or deletion point.
public struct LineDiffHunk: Sendable, Equatable {
    public let oldLines: Range<Int>
    public let newLines: Range<Int>
}

public extension Git {
    static func baselineText(at fileURL: URL) async throws -> String? {
        try await Task.detached(priority: .utility) {
            let fileURL = fileURL.standardizedFileURL
            let directory = fileURL.deletingLastPathComponent()
            let repository = try run(["rev-parse", "--show-toplevel"], at: directory)
            guard repository.status == 0 else { throw GitError.notRepository }
            let pathspec = ":(literal)\(fileURL.lastPathComponent)"
            let files = try run(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", pathspec], at: directory)
            guard files.status == 0 else { throw GitError.commandFailed(files.status) }
            guard !files.data.isEmpty else { return nil }
            let head = try run(["rev-parse", "--verify", "HEAD"], at: directory)
            if head.status != 0 { return "" }
            let added = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "--diff-filter=A", "-z", "HEAD", "--", pathspec], at: directory)
            guard added.status == 0 else { throw GitError.commandFailed(added.status) }
            if !added.data.isEmpty { return "" }
            let untracked = try run(["ls-files", "--others", "--exclude-standard", "-z", "--", pathspec], at: directory)
            guard untracked.status == 0 else { throw GitError.commandFailed(untracked.status) }
            if !untracked.data.isEmpty { return "" }
            let output = try run(["show", "HEAD:./\(fileURL.lastPathComponent)"], at: directory)
            guard output.status == 0 else { throw GitError.commandFailed(output.status) }
            guard let text = String(data: output.data, encoding: .utf8) else { throw GitError.invalidOutput }
            return text
        }.value
    }

    static func diff(from original: String, to source: String) -> [LineDiffHunk] {
        func lines(_ text: String) -> [String] {
            guard !text.isEmpty else { return [] }
            var lines = text.components(separatedBy: "\n")
            for index in 0..<(lines.count - 1) { lines[index] += "\n" }
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let old = lines(original)
        let new = lines(source)
        let changes = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in changes {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [LineDiffHunk] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if removed.contains(oldIndex) || inserted.contains(newIndex) {
                let oldStart = oldIndex
                let newStart = newIndex
                repeat {
                    if removed.contains(oldIndex) { oldIndex += 1 }
                    if inserted.contains(newIndex) { newIndex += 1 }
                } while removed.contains(oldIndex) || inserted.contains(newIndex)
                hunks.append(LineDiffHunk(oldLines: oldStart..<oldIndex, newLines: newStart..<newIndex))
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return hunks
    }

    static func diff(at fileURL: URL) async throws -> [LineDiffHunk] {
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

    private static func allAddedLines(in fileURL: URL) throws -> [LineDiffHunk] {
        let data = try Data(contentsOf: fileURL)
        let lineCount = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (data.isEmpty || data.last == 10 ? 0 : 1)
        return lineCount == 0 ? [] : [LineDiffHunk(oldLines: 0..<0, newLines: 0..<lineCount)]
    }

    private static func parseDiff(_ data: Data) throws -> [LineDiffHunk] {
        let pattern = try NSRegularExpression(pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var hunks: [LineDiffHunk] = []
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
            hunks.append(LineDiffHunk(
                oldLines: oldLower..<(oldLower + oldCount),
                newLines: newLower..<(newLower + newCount)
            ))
        }
        return hunks
    }
}
