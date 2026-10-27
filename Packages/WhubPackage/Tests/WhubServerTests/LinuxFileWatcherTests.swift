// テスト一覧:
// - LinuxFileWatcherTests.detectsFileChangesInAllRoots(): [GITWATCH-F-001]
// - LinuxFileWatcherTests.detectsChangesInNewDirectories(): [GITWATCH-F-002]
// - LinuxFileWatcherTests.doesNotReportFileReads(): [GITWATCH-F-003]

#if os(Linux)
import Foundation
import Testing
@testable import WhubServer

@Suite struct LinuxFileWatcherTests {
    @Test func detectsFileChangesInAllRoots() throws {
        let fixture = try WatchFixture()
        defer { fixture.remove() }
        let worktree = fixture.directory.appendingPathComponent("worktree")
        let git = fixture.directory.appendingPathComponent("git")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let watcher = try LinuxFileWatcher(roots: [worktree, git])

        for root in [worktree, git] {
            let file = root.appendingPathComponent("file")
            try Data("created".utf8).write(to: file)
            #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .changed)
            try drain(watcher)
            try Data("modified".utf8).write(to: file)
            #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .changed)
            try drain(watcher)
            try FileManager.default.removeItem(at: file)
            #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .changed)
            try drain(watcher)
        }
    }

    @Test func detectsChangesInNewDirectories() throws {
        let fixture = try WatchFixture()
        defer { fixture.remove() }
        let watcher = try LinuxFileWatcher(roots: [fixture.directory])
        let child = fixture.directory.appendingPathComponent("new")

        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .rescan)
        try drain(watcher)
        try Data("new".utf8).write(to: child.appendingPathComponent("file"))
        #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .changed)
    }

    @Test func doesNotReportFileReads() throws {
        let fixture = try WatchFixture()
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent("file")
        try Data("text".utf8).write(to: file)
        let watcher = try LinuxFileWatcher(roots: [fixture.directory])

        _ = try Data(contentsOf: file)
        #expect(try watcher.nextEvent(timeoutMilliseconds: 100) == nil)
    }

    private func drain(_ watcher: LinuxFileWatcher) throws {
        while try watcher.nextEvent(timeoutMilliseconds: 0) != nil {}
    }
}

private struct WatchFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("whub-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
#endif
