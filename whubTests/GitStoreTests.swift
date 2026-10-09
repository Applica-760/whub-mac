import Foundation
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct GitStoreTests {
    @Test func rootSwitchDiscardsInFlightStatus() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = GitStore()
        var switched = false
        store.onManagementDirectoriesChange = {
            if !switched {
                switched = true
                store.setRoot(fixture.second)
                store.refresh()
            }
        }
        store.setRoot(fixture.first)
        store.refresh()
        try await eventually { store.changes[fixture.secondFile] == .added }
        #expect(switched)
        #expect(store.rootURL == fixture.second)
        #expect(store.changes[fixture.firstFile] == nil)
        #expect(store.errorMessage == nil)
        #expect(store.managesStatus(for: fixture.secondFile))
        #expect(!store.managesStatus(for: fixture.firstFile))
        store.stop()
        #expect(!store.managesStatus(for: fixture.secondFile))
        #expect(store.changes[fixture.secondFile] == .added)
    }

    @Test func standaloneStatusAndLineDiffFollowCurrentContent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let git = GitStore()
        let lines = GitLineStore()
        await lines.load(fileURL: fixture.firstFile, gitStore: git)
        #expect(git.changes[fixture.firstFile] == .added)
        #expect(lines.baseline?.source == "")
        #expect(lines.errorMessage == nil)
        await lines.update(source: "one\ntwo\n")
        let hunks = lines.hunks(for: fixture.firstFile, source: "one\ntwo\n")
        #expect(hunks.count == 1)
        #expect(hunks.first?.newLines == 0..<2)
        #expect(lines.hunks(for: fixture.secondFile, source: "one\ntwo\n").isEmpty)
        #expect(lines.hunks(for: fixture.firstFile, source: "changed\n").isEmpty)
        let pending = Task { await lines.update(source: "changed\n") }
        await Task.yield()
        pending.cancel()
        await pending.value
        #expect(lines.hunks(for: fixture.firstFile, source: "changed\n").isEmpty)
        await lines.load(fileURL: fixture.secondFile, gitStore: git)
        #expect(lines.hunks(for: fixture.firstFile, source: "one\ntwo\n").isEmpty)
        git.reset()
        #expect(git.changes.isEmpty)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum FixtureError: Error { case gitFailed, timeout }

    private struct Fixture {
        let directory: URL
        let first: URL
        let second: URL
        let firstFile: URL
        let secondFile: URL

        init() throws {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            directory = project.appendingPathComponent("DerivedData/GitStoreTests/" + UUID().uuidString)
            first = directory.appendingPathComponent("first")
            second = directory.appendingPathComponent("second")
            firstFile = first.appendingPathComponent("first.swift")
            secondFile = second.appendingPathComponent("second.swift")
            do {
                for root in [first, second] {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["init", "--quiet", root.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw FixtureError.gitFailed }
                }
                try "original\n".write(to: firstFile, atomically: true, encoding: .utf8)
                try "second\n".write(to: secondFile, atomically: true, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}
