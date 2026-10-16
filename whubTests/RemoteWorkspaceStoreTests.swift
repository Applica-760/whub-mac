// 検証する内容:
// - 登録済みで実在するディレクトリのみをProjectとして並べ、対応する正のIssue番号のWorktreeだけを末尾へ置く。
// - 同じパスのローカル・別ホストを区別し、選択とショートカットの順序を保つ。
// - 切断・再接続後に遅れて返る成功・失敗が新しい一覧を上書きしない。
// - 再取得時に一覧を更新し、一部の取得失敗を空の正常結果として隠さない。
// - ホスト表示名の変更では一覧を再取得せず、既存の一覧・選択を維持する。
// 限界: 通信応答を制御して状態管理を検証する。実SSHとメニューの見た目は別途確認する。
import Foundation
import SwiftData
import SwiftUI
import Testing
import WhubCore
import WhubClient
@testable import whub

@Suite @MainActor
struct RemoteWorkspaceStoreTests {
    private func entries(_ names: [String], kind: String = "directory") throws -> [FilesAPI.FileEntry] {
        let data = try JSONSerialization.data(withJSONObject: names.map { ["name": $0, "kind": kind] })
        return try JSONDecoder().decode([FilesAPI.FileEntry].self, from: data)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func listingIdentityAndSelection() async throws {
        let fixture = try Fixture()
        let sources = [fixture.source(fixture.first), fixture.source(fixture.second)]
        let store = RemoteWorkspaceStore()
        store.update(sources: sources, refreshID: 0, context: fixture.container.mainContext) { source, path in
            if path == source.projectsPath {
                return try entries(source.hostID == fixture.first.persistentModelID ? ["z", "a", "unregistered"] : ["d", "c"]) + entries(["file"], kind: "file") + entries(["missing"], kind: "symlink")
            }
            return try entries(source.hostID == fixture.first.persistentModelID
                ? ["a-10", "a-2", "a-0", "a--1", "a-01", "unknown-1", "a-draft"] : ["c-2", "c-10"])
        }
        try await eventually { sources.allSatisfy { store.states[$0.hostID] == .loaded } }
        let rows = store.entries(for: sources)
        #expect(rows.map(\.name) == ["same", "a", "z", "a-2", "a-10", "same", "c", "d", "c-2", "c-10"])
        #expect(rows[0] != rows[5])
        #expect(rows[0] != .local(URL(fileURLWithPath: "/same")))
        let explorer = ExplorerStore()
        let localHost = try HostStore(context: fixture.container.mainContext).addLocal(name: "local", basePath: "/same")
        let project = try ProjectStore(context: fixture.container.mainContext).add(name: "local-app", gitURL: nil, host: localHost)
        let locations = explorer.availableLocations(projects: [project], remote: rows, basePath: localHost.basePath)
        #expect(locations == [.local(URL(fileURLWithPath: localHost.basePath)), .local(URL(fileURLWithPath: project.path))] + rows)
        explorer.selectedLocation = locations[1]
        let navigation = ExplorerPulldownSelection(locations: locations, selection: Binding(
            get: { explorer.selectedLocation }, set: { explorer.selectedLocation = $0 }
        ))
        navigation.move(by: 1)
        #expect(explorer.selectedLocation == rows[0])
        #expect(explorer.selectedRootURL == nil)
        explorer.validateSelection(projects: [project], remote: [], basePath: localHost.basePath)
        #expect(explorer.selectedLocation == locations[0])
        store.stop()
    }

    @Test func basePathSelectionAndDisabledDirectories() {
        let explorer = ExplorerStore()
        let base = FileLocation.local(URL(fileURLWithPath: "/shared"))
        explorer.validateSelection(projects: [], remote: [], basePath: "/shared")
        #expect(explorer.selectedLocation == base)
        #expect(explorer.basePath(projects: []) == "/shared")
        explorer.validateSelection(projects: [], remote: [], basePath: "/shared")
        #expect(explorer.selectedLocation == base)
        for name in ["projects", "worktrees"] {
            let item = ExplorerItem(location: .local(URL(fileURLWithPath: "/shared/" + name)), isDirectory: true)
            #expect(explorer.isUnavailable(item))
            #expect(explorer.children(for: item).isEmpty)
        }
        for (path, directory) in [("/shared/AGENTS.md", false), ("/shared/.agents", true),
                                  ("/shared/rules/projects", true), ("/shared/projects", false)] {
            #expect(!explorer.isUnavailable(ExplorerItem(location: .local(URL(fileURLWithPath: path)), isDirectory: directory)))
        }
        explorer.selectedLocation = .local(URL(fileURLWithPath: "/shared/projects/app"))
        #expect(!explorer.isUnavailable(ExplorerItem(location: .local(URL(fileURLWithPath: "/shared/projects/app/projects")), isDirectory: true)))
    }

    @Test func renamePreservesListingAndSelection() async throws {
        let fixture = try Fixture()
        let source = fixture.source(fixture.first)
        let store = RemoteWorkspaceStore()
        var requests = 0
        store.update(sources: [source], refreshID: 0, context: fixture.container.mainContext) { source, path in
            requests += 1
            return try entries(path == source.projectsPath ? ["a"] : ["a-1"])
        }
        try await eventually { store.states[source.hostID] == .loaded }
        let locations = store.entries(for: [source])
        let explorer = ExplorerStore()
        let selected = try #require(locations.last)
        explorer.selectedLocation = selected

        let host = fixture.first
        try HostStore(context: fixture.container.mainContext).editRemote(
            host, name: "renamed", basePath: host.basePath, hostname: host.hostname,
            user: host.user, port: host.port, identityFile: host.identityFile
        )
        let renamed = fixture.source(fixture.first)
        #expect(renamed.hostName == "renamed")
        #expect(renamed == source)
        #expect(store.entries(for: [renamed]) == locations)
        store.update(sources: [renamed], refreshID: 0, context: fixture.container.mainContext) { _, _ in
            requests += 1
            Issue.record("表示名だけの変更で一覧を再取得しました。")
            return []
        }
        #expect(store.states[source.hostID] == .loaded)
        explorer.validateSelection(projects: [], remote: store.entries(for: [renamed]), basePath: nil)
        #expect(explorer.selectedLocation == selected)
        #expect(requests == 2)
        store.stop()
    }

    @Test(arguments: [true, false])
    func lateCompletionAfterReconnect(succeeds: Bool) async throws {
        let fixture = try Fixture()
        let old = fixture.source(fixture.first)
        let newSession = NSObject()
        let current = fixture.source(fixture.first, session: newSession)
        let gate = Gate()
        let store = RemoteWorkspaceStore()
        var oldReturned = false
        store.update(sources: [old], refreshID: 0, context: fixture.container.mainContext) { _, _ in
            await gate.wait()
            oldReturned = true
            if !succeeds { throw SSHError.timedOut }
            return try entries(["old"])
        }
        try await eventually { gate.waiting }
        store.update(sources: [], refreshID: 0, context: fixture.container.mainContext) { _, _ in [] }
        #expect(store.entries(for: [old]).isEmpty)
        #expect(store.states.isEmpty)
        store.update(sources: [current], refreshID: 0, context: fixture.container.mainContext) { source, path in
            try entries(path == source.projectsPath ? ["new"] : ["new-1"])
        }
        try await eventually { store.states[current.hostID] == .loaded }
        gate.release()
        try await eventually { oldReturned }
        #expect(store.entries(for: [current]).map(\.name) == ["same", "new", "new-1"])
        #expect(store.entries(for: [old]).isEmpty)
        #expect(store.states[current.hostID] == .loaded)
        store.stop()
    }

    @Test func URLChangeDiscardsLateListingWithoutSSHReconnect() async throws {
        let fixture = try Fixture()
        var old = fixture.source(fixture.first)
        old.serverURL = "http://server:8081"
        var current = old
        current.serverURL = "http://server:8082"
        let gate = Gate()
        let store = RemoteWorkspaceStore()
        var returned = false
        store.update(sources: [old], refreshID: 0, context: fixture.container.mainContext) { _, _ in
            await gate.wait()
            returned = true
            return try entries(["old"])
        }
        try await eventually { gate.waiting }
        store.update(sources: [current], refreshID: 0, context: fixture.container.mainContext) { source, path in
            try entries(path == source.projectsPath ? ["current"] : [])
        }
        try await eventually { store.states[current.hostID] == .loaded }
        gate.release()
        try await eventually { returned }
        #expect(store.entries(for: [current]).map(\.name) == ["same", "current"])
        #expect(store.entries(for: [old]).isEmpty)
        store.stop()
    }

    @Test func refreshAndPartialFailure() async throws {
        let fixture = try Fixture()
        let source = fixture.source(fixture.first)
        let store = RemoteWorkspaceStore()
        store.update(sources: [source], refreshID: 0, context: fixture.container.mainContext) { source, path in
            if path == source.worktreesPath { throw SSHError.operationFailed("permission denied") }
            return try entries(["a"])
        }
        try await eventually {
            if case .failed = store.states[source.hostID] { return true }
            return false
        }
        #expect(store.entries(for: [source]).map(\.name) == ["same", "a"])
        let gate = Gate()
        store.update(sources: [source], refreshID: 1, context: fixture.container.mainContext) { source, path in
            if path == source.projectsPath { await gate.wait(); return try entries(["b"]) }
            return try entries(["b-3"])
        }
        try await eventually { gate.waiting }
        #expect(store.entries(for: [source]).map(\.name) == ["same", "a"])
        #expect(store.states[source.hostID] == .loading)
        gate.release()
        try await eventually { store.states[source.hostID] == .loaded }
        #expect(store.entries(for: [source]).map(\.name) == ["same", "b", "b-3"])
        store.update(sources: [source], refreshID: 1, context: fixture.container.mainContext) { _, _ in
            Issue.record("同じ更新番号で一覧を再取得しました。")
            return []
        }
        #expect(store.states[source.hostID] == .loaded)
        let projects = ProjectStore(context: fixture.container.mainContext)
        for project in try projects.fetchProjects() where project.host === fixture.first {
            try projects.delete(project)
        }
        var emptySource = source
        emptySource.projectNames = []
        store.update(sources: [emptySource], refreshID: 1, context: fixture.container.mainContext) { _, _ in
            Issue.record("Project未登録のHostでProject一覧を取得しました。")
            return []
        }
        #expect(store.entries(for: [emptySource]) == [source.baseLocation])
        try await eventually { store.states[source.hostID] == .loaded }
        #expect(store.entries(for: [emptySource]) == [source.baseLocation])
        store.stop()
    }
}

@MainActor
private struct Fixture {
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
        let projects = ProjectStore(context: container.mainContext)
        for name in ["a", "z", "b", "new", "current", "missing"] {
            try projects.add(name: name, gitURL: nil, host: first)
        }
        for name in ["c", "d"] { try projects.add(name: name, gitURL: nil, host: second) }
    }

    func source(_ host: RemoteHost, session: NSObject? = nil) -> RemoteWorkspaceStore.Source {
        .init(hostID: host.persistentModelID, hostName: host.name,
              projectsPath: host.projectsPath, worktreesPath: host.worktreesPath,
              sessionID: ObjectIdentifier(session ?? self.session),
              projectNames: host === first ? ["a", "b", "current", "missing", "new", "z"] : ["c", "d"])
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
