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
        diff(from: original, to: source, checkCancellation: {})
    }

    static func diff(from original: String, to source: String,
                     checkCancellation: () throws -> Void) rethrows -> [LineDiffHunk] {
        try checkCancellation()
        guard original != source else { return [] }
        func lines(_ text: String) throws -> [String] {
            guard !text.isEmpty else { return [] }
            var result = text.components(separatedBy: "\n")
            for index in 0..<(result.count - 1) {
                if index.isMultiple(of: 256) { try checkCancellation() }
                result[index] += "\n"
            }
            if result.last == "" { result.removeLast() }
            return result
        }
        let oldLines = try lines(original)
        let newLines = try lines(source)
        var oldRange = oldLines.indices, newRange = newLines.indices
        while !oldRange.isEmpty, !newRange.isEmpty, oldLines[oldRange.lowerBound] == newLines[newRange.lowerBound] {
            if oldRange.lowerBound.isMultiple(of: 256) { try checkCancellation() }
            oldRange = (oldRange.lowerBound + 1)..<oldRange.upperBound
            newRange = (newRange.lowerBound + 1)..<newRange.upperBound
        }
        while !oldRange.isEmpty, !newRange.isEmpty, oldLines[oldRange.upperBound - 1] == newLines[newRange.upperBound - 1] {
            if oldRange.upperBound.isMultiple(of: 256) { try checkCancellation() }
            oldRange = oldRange.lowerBound..<(oldRange.upperBound - 1)
            newRange = newRange.lowerBound..<(newRange.upperBound - 1)
        }
        var identifiers: [String: Int] = [:]
        func encode(_ lines: ArraySlice<String>) throws -> [Int] {
            var result: [Int] = []
            for (index, line) in lines.enumerated() {
                if index.isMultiple(of: 256) { try checkCancellation() }
                if let id = identifiers[line] { result.append(id) }
                else {
                    let id = identifiers.count
                    identifiers[line] = id
                    result.append(id)
                }
            }
            return result
        }
        let old = try encode(oldLines[oldRange])
        let new = try encode(newLines[newRange])
        var hunks: [LineDiffHunk] = []
        func append(_ oldRange: Range<Int>, _ newRange: Range<Int>) {
            guard !oldRange.isEmpty || !newRange.isEmpty else { return }
            if let last = hunks.last, last.oldLines.upperBound == oldRange.lowerBound,
               last.newLines.upperBound == newRange.lowerBound {
                hunks[hunks.count - 1] = LineDiffHunk(oldLines: last.oldLines.lowerBound..<oldRange.upperBound,
                                                     newLines: last.newLines.lowerBound..<newRange.upperBound)
            } else { hunks.append(LineDiffHunk(oldLines: oldRange, newLines: newRange)) }
        }

        // Meet in the middle to reconstruct a shortest edit path without storing every frontier.
        func split(_ a: Range<Int>, _ b: Range<Int>) throws -> (Int, Int) {
            let n = a.count, m = b.count
            let limit = (n + m + 1) / 2
            let offset = limit + 1
            var forward = Array(repeating: -1, count: 2 * limit + 3)
            var backward = forward
            forward[offset + 1] = 0
            backward[offset + 1] = 0
            let delta = n - m
            let odd = !delta.isMultiple(of: 2)
            for distance in 0...limit {
                try checkCancellation()
                for k in stride(from: -distance, through: distance, by: 2) {
                    if (k + distance).isMultiple(of: 256) { try checkCancellation() }
                    let index = offset + k
                    var x = k == -distance || (k != distance && forward[index - 1] < forward[index + 1])
                        ? forward[index + 1] : forward[index - 1] + 1
                    var y = x - k
                    while x < n, y < m, x >= 0, y >= 0, old[a.lowerBound + x] == new[b.lowerBound + y] {
                        if x.isMultiple(of: 256) { try checkCancellation() }
                        x += 1; y += 1
                    }
                    forward[index] = x
                    let reverseK = delta - k
                    if odd, abs(reverseK) <= distance - 1,
                       backward[offset + reverseK] >= 0, x >= n - backward[offset + reverseK] {
                        return (a.lowerBound + x, b.lowerBound + y)
                    }
                }
                for k in stride(from: -distance, through: distance, by: 2) {
                    if (k + distance).isMultiple(of: 256) { try checkCancellation() }
                    let index = offset + k
                    var x = k == -distance || (k != distance && backward[index - 1] < backward[index + 1])
                        ? backward[index + 1] : backward[index - 1] + 1
                    var y = x - k
                    while x < n, y < m, x >= 0, y >= 0, old[a.upperBound - x - 1] == new[b.upperBound - y - 1] {
                        if x.isMultiple(of: 256) { try checkCancellation() }
                        x += 1; y += 1
                    }
                    backward[index] = x
                    let forwardK = delta - k
                    if !odd, abs(forwardK) <= distance,
                       forward[offset + forwardK] >= 0, forward[offset + forwardK] >= n - x {
                        let forwardX = forward[offset + forwardK]
                        return (a.lowerBound + forwardX, b.lowerBound + forwardX - forwardK)
                    }
                }
            }
            preconditionFailure("A shortest edit path must cross the two search frontiers")
        }

        func compare(_ oldRange: Range<Int>, _ newRange: Range<Int>) throws {
            try checkCancellation()
            var a = oldRange, b = newRange
            while !a.isEmpty, !b.isEmpty, old[a.lowerBound] == new[b.lowerBound] {
                if a.lowerBound.isMultiple(of: 256) { try checkCancellation() }
                a = (a.lowerBound + 1)..<a.upperBound
                b = (b.lowerBound + 1)..<b.upperBound
            }
            while !a.isEmpty, !b.isEmpty, old[a.upperBound - 1] == new[b.upperBound - 1] {
                if a.upperBound.isMultiple(of: 256) { try checkCancellation() }
                a = a.lowerBound..<(a.upperBound - 1)
                b = b.lowerBound..<(b.upperBound - 1)
            }
            guard !a.isEmpty, !b.isEmpty else { append(a, b); return }
            var oldIDs = Set<Int>()
            for i in a {
                if i.isMultiple(of: 256) { try checkCancellation() }
                oldIDs.insert(old[i])
            }
            var sharesLine = false
            for j in b {
                if j.isMultiple(of: 256) { try checkCancellation() }
                if oldIDs.contains(new[j]) { sharesLine = true; break }
            }
            guard sharesLine else { append(a, b); return }
            if a.count == 1 {
                let match = b.first { new[$0] == old[a.lowerBound] }!
                append(a.lowerBound..<a.lowerBound, b.lowerBound..<match)
                append(a.upperBound..<a.upperBound, (match + 1)..<b.upperBound)
            } else if b.count == 1 {
                let match = a.first { old[$0] == new[b.lowerBound] }!
                append(a.lowerBound..<match, b.lowerBound..<b.lowerBound)
                append((match + 1)..<a.upperBound, b.upperBound..<b.upperBound)
            } else {
                let (x, y) = try split(a, b)
                try compare(a.lowerBound..<x, b.lowerBound..<y)
                try compare(x..<a.upperBound, y..<b.upperBound)
            }
        }
        try compare(old.indices, new.indices)
        try checkCancellation()
        return hunks.map {
            LineDiffHunk(oldLines: ($0.oldLines.lowerBound + oldRange.lowerBound)..<($0.oldLines.upperBound + oldRange.lowerBound),
                         newLines: ($0.newLines.lowerBound + newRange.lowerBound)..<($0.newLines.upperBound + newRange.lowerBound))
        }
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
