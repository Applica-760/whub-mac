import Foundation
import Testing
@testable import WhubGit

struct LineDiffTests {
    @Test func preservesUnchangedLinesAndShortestEditCount() {
        var seed: UInt64 = 42
        func next(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int(seed >> 32) % count
        }
        let alphabet = ["a\n", "b\n", "\n", "日本語😀\r\n", "e\u{301}\n", "é\n"]
        for _ in 0..<1000 {
            let old = (0..<next(30)).map { _ in alphabet[next(alphabet.count)] }
            let new = (0..<next(30)).map { _ in alphabet[next(alphabet.count)] }
            let hunks = Git.diff(from: old.joined(), to: new.joined())
            var i = 0, j = 0
            for hunk in hunks {
                #expect(hunk.oldLines.lowerBound >= i && hunk.newLines.lowerBound >= j)
                #expect(Array(old[i..<hunk.oldLines.lowerBound]) == Array(new[j..<hunk.newLines.lowerBound]))
                i = hunk.oldLines.upperBound
                j = hunk.newLines.upperBound
            }
            #expect(Array(old[i...]) == Array(new[j...]))
            #expect(hunks.reduce(0) { $0 + $1.oldLines.count + $1.newLines.count } == new.difference(from: old).count)
        }
    }

    @Test func keepsLineEndingsAndEmptyFileChanges() {
        #expect(Git.diff(from: "", to: "").isEmpty)
        #expect(Git.diff(from: "", to: "a\r\nb").first == LineDiffHunk(oldLines: 0..<0, newLines: 0..<2))
        #expect(Git.diff(from: "a\r\nb", to: "").first == LineDiffHunk(oldLines: 0..<2, newLines: 0..<0))
        #expect(Git.diff(from: "same\nlast", to: "same\nlast\n") == [LineDiffHunk(oldLines: 1..<2, newLines: 1..<2)])
        #expect(Git.diff(from: "a\r\nb\r\n", to: "a\r\nc\r\n") == [LineDiffHunk(oldLines: 1..<2, newLines: 1..<2)])
    }

    @Test func stopsDuringSearchWithoutReturningPartialHunks() {
        let old = (0..<1000).map { "line\($0)\n" }
        var checks = 0
        #expect(throws: CancellationError.self) {
            try Git.diff(from: old.joined(), to: old.reversed().joined()) {
                checks += 1
                if checks == 200 { throw CancellationError() }
            }
        }
        #expect(checks == 200)
    }
}
