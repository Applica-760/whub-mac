// テスト一覧:
// - GitAPITests.listsSavedChangesAgainstHEAD(): [GITAPI-F-001]
// - GitAPITests.returnsBeforeAndAfterForChangedAndDeletedFiles(): [GITAPI-F-002]
// - GitAPITests.reportsUnsupportedBinaryContent(): [GITAPI-F-003]
// - GitAPITests.rejectsInvalidPaths(): [GITAPI-F-004]
// - GitAPITests.reportsNonRepository(): [GITAPI-F-005]
// - GitAPITests.notifiesAndReleasesWatch(): [GITWATCH-F-004]
// - GitAPITests.ignoresUntrackedDirectoriesButWatchesTrackedFiles(): [GITWATCH-F-005]
// - GitAPITests.rechecksIgnoreRules(): [GITWATCH-F-006]
// - GitAPITests.reportsWatchErrors(): [GITWATCH-F-007]

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
import WhubAgent
@testable import WhubServer
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite struct GitAPITests {
    #if os(Linux)
    @Test func reportsWatchErrors() async throws {
        let limit = LinuxFileWatcher.SystemError(operation: "inotify_add_watch", code: ENOSPC)
        let failure = LinuxFileWatcher.SystemError(operation: "poll", code: EIO)
        for (store, expected) in [
            (LinuxGitWatchStore(makeWatcher: { _, _, _ in throw limit }), "watch_limit_reached"),
            (LinuxGitWatchStore(makeWatcher: { _, _, _ in throw failure }), "watch_failed"),
        ] {
            let fixture = try await GitFixture(git: GitAPI(watches: store))
            defer { fixture.remove() }
            try await fixture.app.test(.router) { client in
                let response = try await client.execute(uri: fixture.uri("watches"), method: .post)
                #expect(response.status == .serviceUnavailable)
                let body = try JSONDecoder().decode([String: [String: String]].self, from: Data(response.body.readableBytesView))
                #expect(body["error"]?["code"] == expected)
                #expect(body["error"]?["message"]?.isEmpty == false)
            }
        }

        let store = LinuxGitWatchStore(nextEvent: { _ in throw limit })
        let fixture = try await GitFixture(git: GitAPI(watches: store))
        defer { fixture.remove() }
        try await fixture.app.test(.router) { client in
            let start = try await client.execute(uri: fixture.uri("watches"), method: .post)
            #expect(start.status == .ok)
            let watch = try JSONDecoder().decode(WatchResponse.self, from: Data(start.body.readableBytesView))
            let failed = try await client.execute(uri: "/git/watches/\(watch.id)?after=0", method: .get)
            #expect(failed.status == .serviceUnavailable)
            let body = try JSONDecoder().decode([String: [String: String]].self, from: Data(failed.body.readableBytesView))
            #expect(body["error"]?["code"] == "watch_limit_reached")
            _ = try await client.execute(uri: "/git/watches/\(watch.id)", method: .delete)
            let expired = try await client.execute(uri: "/git/watches/\(watch.id)?after=0", method: .get)
            #expect(expired.status == .gone)
            let expiredBody = try JSONDecoder().decode([String: [String: String]].self, from: Data(expired.body.readableBytesView))
            #expect(expiredBody["error"]?["code"] == "watch_expired")
        }
        await store.shutdown()
    }

    @Test func ignoresUntrackedDirectoriesButWatchesTrackedFiles() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("ignored/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tracked"), withIntermediateDirectories: true)
        try fixture.write(".gitignore", "ignored/\ntracked/\n")
        try fixture.write("ignored/nested/file", "ignored")
        try fixture.write("tracked/file", "tracked")
        try fixture.git(["add", "-f", "tracked/file"])
        let git = fixture.root.appendingPathComponent(".git")
        let watcher = try LinuxFileWatcher(roots: [fixture.root, git], worktree: fixture.root, managementDirectories: [git])
        try fixture.write("ignored/nested/file", "modified")
        #expect(try watcher.nextEvent(timeoutMilliseconds: 150) == nil)
        try fixture.write("tracked/file", "modified")
        #expect(try watcher.nextEvent(timeoutMilliseconds: 2_000) == .changed)
    }

    @Test func rechecksIgnoreRules() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try fixture.write(".gitignore", "ignored/\n")
        try fixture.write("ignored/file", "before")
        let store = LinuxGitWatchStore()
        let watch = try await store.start(root: fixture.root.path)
        try fixture.write(".gitignore", "")
        let updated = try await store.wait(id: watch.id, after: watch.revision, timeout: .seconds(3))
        #expect(updated != nil)
        try fixture.write("ignored/file", "after")
        let changed = try await store.wait(id: watch.id, after: try #require(updated), timeout: .seconds(3))
        #expect(changed != nil)
        await store.shutdown()
    }

    @Test func notifiesAndReleasesWatch() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try await fixture.app.test(.router) { client in
            let start = try await client.execute(uri: fixture.uri("watches"), method: .post)
            #expect(start.status == .ok)
            let watch = try JSONDecoder().decode(WatchResponse.self, from: Data(start.body.readableBytesView))
            let unchanged = try await client.execute(uri: "/git/watches/\(watch.id)?after=\(watch.revision)", method: .get)
            #expect(unchanged.status == .noContent)
            let writer = Task {
                try await Task.sleep(for: .milliseconds(200))
                try fixture.write("watched.txt", "changed")
            }
            let changed = try await client.execute(uri: "/git/watches/\(watch.id)?after=\(watch.revision)", method: .get)
            try await writer.value
            #expect(changed.status == .ok)
            let update = try JSONDecoder().decode(WatchUpdate.self, from: Data(changed.body.readableBytesView))
            #expect(update.revision > watch.revision)
            let stop = try await client.execute(uri: "/git/watches/\(watch.id)", method: .delete)
            #expect(stop.status == .noContent)
            let expired = try await client.execute(uri: "/git/watches/\(watch.id)?after=0", method: .get)
            #expect(expired.status == .gone)
        }
    }
    #endif
    @Test func listsSavedChangesAgainstHEAD() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try fixture.write("changed.txt", "before")
        try fixture.write("restored.txt", "before")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-q", "-m", "initial"])
        try fixture.write("changed.txt", "after")
        try fixture.write("restored.txt", "staged")
        try fixture.git(["add", "restored.txt"])
        try fixture.write("restored.txt", "before")
        try fixture.write("new + 日本語.txt", "new")

        try await fixture.app.test(.router) { client in
            let response = try await client.execute(uri: fixture.uri("changes"), method: .get)
            #expect(response.status == .ok)
            let result = try JSONDecoder().decode([[String: String]].self, from: Data(response.body.readableBytesView))
            #expect(result == [["path": "changed.txt", "change": "modified"],
                               ["path": "new + 日本語.txt", "change": "added"]])
        }
    }

    @Test func returnsBeforeAndAfterForChangedAndDeletedFiles() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try fixture.write("changed.txt", "before")
        try fixture.write("deleted.txt", "removed")
        try fixture.git(["add", "."])
        try fixture.git(["commit", "-q", "-m", "initial"])
        try fixture.write("changed.txt", "after")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("deleted.txt"))

        try await fixture.app.test(.router) { client in
            for (path, change, before, after) in [("changed.txt", "modified", "before", "after"),
                                                   ("deleted.txt", "deleted", "removed", "")] {
                let response = try await client.execute(uri: fixture.uri("diff", path: path), method: .get)
                #expect(response.status == .ok)
                let result = try JSONDecoder().decode(DiffResponse.self, from: Data(response.body.readableBytesView))
                #expect(result.path == path)
                #expect(result.change == change)
                #expect(result.content.type == "text")
                #expect(result.content.before == before)
                #expect(result.content.after == after)
            }
        }
    }

    @Test func reportsUnsupportedBinaryContent() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary"))

        try await fixture.app.test(.router) { client in
            let response = try await client.execute(uri: fixture.uri("diff", path: "binary"), method: .get)
            #expect(response.status == .ok)
            let result = try JSONDecoder().decode(DiffResponse.self, from: Data(response.body.readableBytesView))
            #expect(result.change == "added")
            #expect(result.content.type == "unsupported")
            #expect(result.content.reason == "binary")
        }
    }

    @Test func rejectsInvalidPaths() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }

        try await fixture.app.test(.router) { client in
            for uri in [fixture.uri("diff", path: "../outside"), fixture.uri("diff", path: "/absolute"),
                        fixture.uri("diff"), fixture.uri("changes") + "&root=/", "/git/changes?root=relative"] {
                let response = try await client.execute(uri: uri, method: .get)
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func reportsNonRepository() async throws {
        let fixture = try await GitFixture()
        defer { fixture.remove() }
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw GitFixtureError.invalidTemporaryDirectory
        }
        defer { free(resolved) }
        let nonRepository = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("whub-git-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: nonRepository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepository) }

        try await fixture.app.test(.router) { client in
            let response = try await client.execute(uri: fixture.uri("changes", root: nonRepository), method: .get)
            #expect(response.status == .unprocessableContent)
            let body = try JSONDecoder().decode([String: [String: String]].self, from: Data(response.body.readableBytesView))
            #expect(body["error"]?["code"] == "not_repository")
        }
    }
}

#if os(Linux)
private struct WatchResponse: Decodable { let id: UUID; let revision: UInt64 }
private struct WatchUpdate: Decodable { let revision: UInt64 }
#endif

private struct DiffResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let before: String?
        let after: String?
        let reason: String?
    }
    let path: String
    let change: String?
    let content: Content
}

private final class GitFixture: Sendable {
    let root: URL
    let app: Application<RouterResponder<BasicRequestContext>>

    init(git: GitAPI = GitAPI()) async throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw GitFixtureError.invalidTemporaryDirectory
        }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("whub-git-api-\(UUID().uuidString)/repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = ManagerConfiguration(environment: .dev, source: root, swift: "/usr/bin/swift",
                                                 service: "fixture", healthURL: URL(string: "http://127.0.0.1/ping")!)
        let manager = ManagerAPI(manager: ServerManager(root: root), configuration: configuration,
                                 executable: root, running: nil)
        app = Application(router: makeRouter(files: FilesAPI(), manager: manager, agent: AgentAPI(runtime: await AgentRuntime()), git: git))
        do { try self.git(["init", "-q", "-b", "main"]) }
        catch { remove(); throw error }
    }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitFixtureError.commandFailed(process.terminationStatus) }
    }

    func uri(_ endpoint: String, root: URL? = nil, path: String? = nil) -> String {
        var components = URLComponents()
        components.path = "/git/\(endpoint)"
        components.queryItems = [URLQueryItem(name: "root", value: (root ?? self.root).path)]
        if let path { components.queryItems!.append(URLQueryItem(name: "path", value: path)) }
        return components.string!.replacingOccurrences(of: "+", with: "%2B")
    }

    func remove() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
}

private enum GitFixtureError: Error { case invalidTemporaryDirectory, commandFailed(Int32) }
