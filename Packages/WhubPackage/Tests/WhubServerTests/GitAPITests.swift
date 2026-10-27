// テスト一覧:
// - GitAPITests.listsSavedChangesAgainstHEAD(): [GITAPI-F-001]
// - GitAPITests.returnsBeforeAndAfterForChangedAndDeletedFiles(): [GITAPI-F-002]
// - GitAPITests.reportsUnsupportedBinaryContent(): [GITAPI-F-003]
// - GitAPITests.rejectsInvalidPaths(): [GITAPI-F-004]
// - GitAPITests.reportsNonRepository(): [GITAPI-F-005]

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

    init() async throws {
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
        app = Application(router: makeRouter(files: FilesAPI(), manager: manager, agent: AgentAPI(runtime: await AgentRuntime())))
        do { try git(["init", "-q", "-b", "main"]) }
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
