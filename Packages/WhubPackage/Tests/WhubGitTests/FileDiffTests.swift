import Foundation
import Testing
@testable import WhubGit

struct FileDiffTests {
    @Test func comparesHEADWithDiskAndOmitsIndexOnlyChanges() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("changed.txt", "original\n")
        try repo.write("reverted.txt", "original\n")
        try repo.commit()
        try repo.write("changed.txt", "staged\n")
        try repo.write("reverted.txt", "staged\n")
        try repo.write("vanished.txt", "staged\n")
        try repo.git(["add", "."])
        try repo.write("changed.txt", "saved\n")
        try repo.write("reverted.txt", "original\n")
        try FileManager.default.removeItem(at: repo.url("vanished.txt"))

        let changes = try await Git.fileChanges(at: repo.root)
        #expect(changes == [repo.url("changed.txt"): .modified])
        let diff = try await Git.fileDiff(at: repo.url("changed.txt"), in: repo.root)
        #expect(diff.relativePath == "changed.txt")
        #expect(diff.content == .text(before: "original\n", after: "saved\n"))
        let reverted = try await Git.fileDiff(at: repo.url("reverted.txt"), in: repo.root)
        #expect(reverted.change == nil)
    }

    @Test func includesStagedAndUnstagedChangesAndEmptyFiles() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("staged.txt", "old\n")
        try repo.write("unstaged.txt", "old\n")
        try repo.write("empty-deleted.txt", "")
        try repo.commit()
        try repo.write("staged.txt", "staged\n")
        try repo.git(["add", "staged.txt"])
        try repo.write("unstaged.txt", "saved\n")
        try repo.write("empty-added.txt", "")
        try FileManager.default.removeItem(at: repo.url("empty-deleted.txt"))
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url("staged.txt"): .modified, repo.url("unstaged.txt"): .modified,
            repo.url("empty-added.txt"): .added, repo.url("empty-deleted.txt"): .deleted,
        ])
        #expect(try await Git.fileDiff(at: repo.url("staged.txt"), in: repo.root).content
                == .text(before: "old\n", after: "staged\n"))
    }

    @Test func readsDeletedParentsAndRenamesAsDeleteAndAdd() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("gone/nested/file.txt", "deleted\n")
        try repo.write("old.txt", "renamed\n")
        try repo.commit()
        try FileManager.default.removeItem(at: repo.url("gone"))
        try repo.git(["mv", "old.txt", "new.txt"])
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url("gone/nested/file.txt"): .deleted,
            repo.url("old.txt"): .deleted, repo.url("new.txt"): .added,
        ])
        #expect(try await Git.fileDiff(at: repo.url("gone/nested/file.txt"), in: repo.root).content
                == .text(before: "deleted\n", after: ""))
        #expect(try await Git.fileDiff(at: repo.url("new.txt"), in: repo.root).content
                == .text(before: "", after: "renamed\n"))
    }

    @Test func handlesUnbornHEADIgnoredFilesAndLiteralPaths() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        let path = "sub/日本語\tname\n[1]:*.txt"
        try repo.write(".gitignore", "ignored.txt\n")
        try repo.write("ignored.txt", "ignored")
        try repo.write("staged.txt", "")
        try repo.git(["add", "staged.txt"])
        try repo.write(path, "\u{FEFF}one\r\ntwo")
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url(".gitignore"): .added, repo.url("staged.txt"): .added, repo.url(path): .added,
        ])
        try repo.commit()
        try repo.write(path, "\u{FEFF}one\r\nchanged")
        #expect(try await Git.fileChanges(at: repo.url("sub")) == [repo.url(path): .modified])
        #expect(try await Git.fileDiff(at: repo.url(path), in: repo.root).content
                == .text(before: "\u{FEFF}one\r\ntwo", after: "\u{FEFF}one\r\nchanged"))
    }

    @Test func recognizesBinaryAndNonUTF8WithoutLosingListEntries() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("binary", "before\0")
        try repo.commit()
        try repo.write("binary", "now text")
        try Data([0xff, 0xfe]).write(to: repo.url("non-utf8"))
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url("binary"): .modified, repo.url("non-utf8"): .added,
        ])
        for path in ["binary", "non-utf8"] {
            #expect(try await Git.fileDiff(at: repo.url(path), in: repo.root).content == .unsupported(.binary))
        }
    }

    @Test func marksConflictsAsUnsupportedEvenWhenDiskMatchesHEAD() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("conflict.txt", "base\n")
        try repo.commit()
        try repo.git(["checkout", "-q", "-b", "other"])
        try repo.write("conflict.txt", "other\n")
        try repo.commit()
        try repo.git(["checkout", "-q", "main"])
        try repo.write("conflict.txt", "main\n")
        try repo.commit()
        #expect(try repo.git(["merge", "--no-edit", "other"], expectedStatus: 1).isEmpty == false)
        try repo.write("conflict.txt", "main\n")
        #expect(try await Git.fileChanges(at: repo.root) == [repo.url("conflict.txt"): .modified])
        #expect(try await Git.fileDiff(at: repo.url("conflict.txt"), in: repo.root).content
                == .unsupported(.conflict))
    }

    @Test func identifiesNewAndDeletedSubmodules() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("baseline", "content")
        try repo.commit()
        let revision = try repo.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        try repo.git(["update-index", "--add", "--cacheinfo", "160000," + revision + ",module"])
        try FileManager.default.createDirectory(at: repo.url("module"), withIntermediateDirectories: true)
        #expect(try await Git.fileDiff(at: repo.url("module"), in: repo.root).content == .unsupported(.submodule))
        #expect(try await Git.fileChanges(at: repo.root)[repo.url("module")] == .added)
        try repo.git(["commit", "-q", "-m", "submodule"])
        try repo.git(["update-index", "--force-remove", "module"])
        try FileManager.default.removeItem(at: repo.url("module"))
        #expect(try await Git.fileDiff(at: repo.url("module"), in: repo.root).content == .unsupported(.submodule))
        #expect(try await Git.fileChanges(at: repo.root)[repo.url("module")] == .deleted)
    }

    @Test func supportsFileDirectoryReplacementAndRestoredIndexDeletion() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("file", "old")
        try repo.write("restored", "same")
        try repo.commit()
        try FileManager.default.removeItem(at: repo.url("file"))
        try repo.write("file/child", "new")
        try repo.git(["rm", "--cached", "restored"])
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url("file"): .deleted, repo.url("file/child"): .added,
        ])
        #expect(try await Git.fileDiff(at: repo.url("file"), in: repo.root).content == .text(before: "old", after: ""))
        try repo.commit()
        try FileManager.default.removeItem(at: repo.url("file"))
        try repo.write("file", "replacement")
        #expect(try await Git.fileChanges(at: repo.root) == [
            repo.url("file"): .added, repo.url("file/child"): .deleted,
        ])
    }

    @Test func rejectsOutsidePathsAndDoesNotFollowSymlinks() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("parent/file", "original")
        try repo.commit()
        try FileManager.default.removeItem(at: repo.url("parent"))
        try FileManager.default.createSymbolicLink(at: repo.url("parent"), withDestinationURL: repo.root.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: repo.url("link"), withDestinationURL: repo.url("parent"))
        #expect(try await Git.fileDiff(at: repo.url("parent/file"), in: repo.root).content == .unsupported(.symbolicLink))
        #expect(try await Git.fileDiff(at: repo.url("link"), in: repo.root).content == .unsupported(.symbolicLink))
        await #expect(throws: CocoaError.self) {
            try await Git.fileDiff(at: repo.url("../outside"), in: repo.root)
        }
        await #expect(throws: GitError.self) {
            try await Git.fileDiff(at: repo.url("file"), in: repo.url(".git"))
        }
    }

    @Test func retainsExecutableBitChanges() async throws {
        let repo = try Repository()
        defer { repo.remove() }
        try repo.write("script", "echo hello\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.url("script").path)
        try repo.commit()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.url("script").path)
        #expect(try await Git.fileChanges(at: repo.root) == [repo.url("script"): .modified])
        #expect(try await Git.fileDiff(at: repo.url("script"), in: repo.root).content
                == .text(before: "echo hello\n", after: "echo hello\n"))
    }

    private struct Repository {
        let root: URL

        init() throws {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            root = package.appendingPathComponent(".build/FileDiffTests/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do { try git(["init", "-q", "-b", "main"]) }
            catch { remove(); throw error }
        }

        func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

        func write(_ path: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(path))
        }

        func commit() throws {
            try git(["add", "."])
            try git(["commit", "-q", "-m", "fixture"])
        }

        @discardableResult
        func git(_ arguments: [String], expectedStatus: Int32 = 0) throws -> String {
            let output = try Git.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments, at: root)
            guard output.status == expectedStatus else { throw GitError.commandFailed(output.status) }
            return String(decoding: output.data, as: UTF8.self)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
