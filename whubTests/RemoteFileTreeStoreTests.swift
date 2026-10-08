// 検証する内容:
// - ルート・子階層の遅延取得、重複取得の防止、表示順と危険な名前の除外。
// - 同一パスの別ホスト・ローカルを区別し、切り替え・切断・再接続後の古い応答を破棄。
// - エラーを空の成功結果にせず、リロードで再取得して既存ノードの識別を保つ。
// 限界: 応答を制御した状態管理テスト。実SSHと画面上の展開・選択・スクロールは別途確認する。
import Foundation
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct RemoteFileTreeStoreTests {
    private func entries(_ names: [String], kind: String = "file") throws -> [RemoteFileEntry] {
        let data = try JSONSerialization.data(withJSONObject: names.map { ["name": $0, "kind": kind] })
        return try JSONDecoder().decode([RemoteFileEntry].self, from: data)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RemoteSessionError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func hierarchyAndDuplicateRequests() async throws {
        let fixture = try TreeFixture()
        let store = RemoteFileTreeStore()
        let gate = TreeGate()
        var paths: [String] = []
        store.update(source: fixture.source(), refreshID: 0) { path in
            paths.append(path)
            if path.isEmpty {
                return try entries(["z.txt", ".env", "z.txt", "..", "bad/name", ".git", "bad\0name"])
                    + entries(["src"], kind: "directory") + entries(["link"], kind: "symlink")
            }
            await gate.wait()
            return try entries(["child.swift"])
        }
        try await eventually { store.states[""] == .loaded }
        #expect(paths == [""])
        #expect(store.rootItems.map { $0.location.name } == ["src", ".env", "link", "z.txt"])
        let directory = try #require(store.rootItems.first)
        #expect(store.rootItems[2].isDirectory == false)
        #expect(store.children(for: directory).isEmpty)
        store.loadChildren(of: directory)
        try await eventually { gate.waiting }
        store.loadChildren(of: directory)
        #expect(paths == ["", "src"])
        #expect(store.states["src"] == .loading)
        gate.release()
        try await eventually { store.states["src"] == .loaded }
        #expect(store.children(for: directory).map(\.location) == [fixture.source().root.appending("src/child.swift")])
        store.loadChildren(of: directory)
        #expect(paths == ["", "src"])
        store.stop()
    }

    @Test(arguments: [true, false])
    func staleResponsesAfterHostSwitchAndDisconnect(succeeds: Bool) async throws {
        let fixture = try TreeFixture()
        let store = RemoteFileTreeStore()
        let gate = TreeGate()
        var returned = false
        let old = fixture.source()
        let new = fixture.source(second: true)
        #expect(old.root != new.root)
        #expect(old.root != .local(URL(fileURLWithPath: old.root.path)))
        store.update(source: old, refreshID: 0) { _ in
            await gate.wait()
            returned = true
            if !succeeds { throw RemoteSessionError.timedOut }
            return try entries(["old"])
        }
        try await eventually { gate.waiting }
        store.update(source: new, refreshID: 0) { _ in try entries(["new"]) }
        try await eventually { store.states[""] == .loaded }
        gate.release()
        try await eventually { returned }
        #expect(store.rootItems.map(\.location) == [new.root.appending("new")])
        let disconnectGate = TreeGate()
        var disconnectedReturned = false
        store.update(source: new, refreshID: 1) { _ in
            await disconnectGate.wait()
            disconnectedReturned = true
            return try entries(["disconnected"])
        }
        try await eventually { disconnectGate.waiting }
        store.stop()
        let nextSession = NSObject()
        let reconnected = RemoteFileTreeStore.Source(root: new.root, sessionID: ObjectIdentifier(nextSession))
        store.update(source: reconnected, refreshID: 1) { _ in try entries(["reconnected"]) }
        try await eventually { store.states[""] == .loaded }
        disconnectGate.release()
        try await eventually { disconnectedReturned }
        #expect(store.rootItems.map { $0.location.name } == ["reconnected"])
        #expect(store.states[""] == .loaded)
        store.stop()
    }

    @Test func selectionChangeAndRemovedDirectory() async throws {
        let fixture = try TreeFixture()
        let store = RemoteFileTreeStore()
        let source = fixture.source()
        store.update(source: source, refreshID: 0) { path in
            try entries(path.isEmpty ? ["src"] : ["nested"], kind: "directory")
        }
        try await eventually { store.states[""] == .loaded }
        let directory = try #require(store.rootItems.first)
        store.loadChildren(of: directory)
        try await eventually { store.states["src"] == .loaded }
        store.update(source: source, refreshID: 1) { path in
            if path.isEmpty { return [] }
            throw RemoteSessionError.remote(-32000, "deleted")
        }
        try await eventually { store.states[""] == .loaded }
        #expect(store.rootItems.isEmpty)
        #expect(store.cachedItems.isEmpty)
        #expect(store.states["src"] == nil)

        let gate = TreeGate()
        var returned = false
        store.update(source: source, refreshID: 2) { _ in
            await gate.wait()
            returned = true
            return try entries(["old"])
        }
        try await eventually { gate.waiting }
        let anotherRoot = RemoteFileTreeStore.Source(root: source.root.appending("another"), sessionID: source.sessionID)
        store.update(source: anotherRoot, refreshID: 2) { _ in try entries(["current"]) }
        try await eventually { store.states[""] == .loaded }
        gate.release()
        try await eventually { returned }
        #expect(store.rootItems.map(\.location) == [anotherRoot.root.appending("current")])
        store.stop()
    }

    @Test func failureAndRefreshPreserveNodes() async throws {
        let fixture = try TreeFixture()
        let store = RemoteFileTreeStore()
        let source = fixture.source()
        store.update(source: source, refreshID: 0) { path in
            if path.isEmpty { return try entries(["src"], kind: "directory") }
            throw RemoteSessionError.remote(-32000, "permission denied")
        }
        try await eventually { store.states[""] == .loaded }
        let directory = try #require(store.rootItems.first)
        store.loadChildren(of: directory)
        try await eventually { store.states["src"] == .failed("permission denied") }
        #expect(store.rootItems.first === directory)
        store.update(source: source, refreshID: 1) { path in
            if path.isEmpty { return try entries(["src"], kind: "directory") }
            return try entries(["new.swift"])
        }
        try await eventually { store.states[""] == .loaded && store.states["src"] == .loaded }
        #expect(store.rootItems.first === directory)
        #expect(store.children(for: directory).map { $0.location.name } == ["new.swift"])
        store.update(source: source, refreshID: 1) { _ in
            Issue.record("同じ更新番号で再取得しました")
            return []
        }
        #expect(store.states[""] == .loaded)
        store.stop()
    }
}

@MainActor
private struct TreeFixture {
    let container: ModelContainer
    let first: RemoteHost
    let second: RemoteHost
    let session = NSObject()

    init() throws {
        container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let hosts = HostStore(context: container.mainContext)
        first = try hosts.addRemote(name: "one", basePath: "/same", hostname: "unused", user: "test", identityFile: "")
        second = try hosts.addRemote(name: "two", basePath: "/same", hostname: "unused", user: "test", identityFile: "")
    }

    func source(second: Bool = false) -> RemoteFileTreeStore.Source {
        .init(root: .remote(hostID: (second ? self.second : first).persistentModelID, path: "/same/project"),
              sessionID: ObjectIdentifier(session))
    }
}

@MainActor
private final class TreeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
