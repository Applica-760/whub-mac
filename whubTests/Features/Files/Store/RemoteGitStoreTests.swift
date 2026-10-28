// テスト一覧:
// - RemoteGitStoreTests.refreshesChangesAndVisibleDiffOnNotification(): [RGITSTORE-F-001]
// - RemoteGitStoreTests.stopsWhileDisconnectedAndReloadsOnReconnect(): [RGITSTORE-F-002]
// - RemoteGitStoreTests.discardsResultFromPreviousConnection(): [RGITSTORE-F-003]
// - RemoteGitStoreTests.retriesServerFailureOnlyWhileConnected(): [RGITSTORE-F-004]
// - RemoteGitStoreTests.watchLimitRequiresManualRetry(): [RGITSTORE-F-005]
// - RemoteGitStoreTests.sharesWatchBetweenListAndDiff()
// - RemoteGitStoreTests.convertsChangesForRemoteFiles()
// - RemoteGitStoreTests.lineMarkersFollowBaselineAndUnsavedContent()

import Foundation
import SwiftData
import Testing
import WhubClient
import WhubGit
@testable import WhubCore
@testable import whub

@Suite(.serialized) @MainActor
struct RemoteGitStoreTests {
    @Test func lineMarkersFollowBaselineAndUnsavedContent() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        let location = fixture.store.root.appending("file.txt")
        let lines = GitLineStore()
        await fixture.connections.connect(fixture.host)
        let editor = UUID()
        let diff = UUID()
        fixture.store.setUsage(id: editor, listVisible: false, visibleDiffPaths: ["file.txt"])
        fixture.store.setUsage(id: diff, listVisible: false, visibleDiffPaths: ["file.txt"])
        try await eventually { fixture.store.diffs["file.txt"] != nil && GitProtocol.state.waitCount > 0 }
        lines.setBaseline(location: location, source: fixture.store.diffs["file.txt"]?.content.before)
        await lines.update(source: "unsaved")
        #expect(lines.hunks(for: location, source: "unsaved").count == 1)
        #expect(lines.hunks(for: location, source: "original").isEmpty)
        lines.setBaseline(location: location, source: "unsaved")
        #expect(lines.hunks(for: location, source: "unsaved").isEmpty)
        await lines.update(source: "unsaved")
        #expect(lines.hunks(for: location, source: "unsaved").isEmpty)
        fixture.store.setUsage(id: diff, listVisible: false, visibleDiffPaths: [])
        #expect(fixture.store.diffs["file.txt"] != nil)
        await fixture.connections.disconnect(fixture.host)
        try await eventually { !fixture.store.isConnected && fixture.store.diffs.isEmpty }
        lines.setBaseline(location: location, source: nil)
        #expect(lines.baseline == nil)
        await fixture.close()
    }

    @Test func convertsChangesForRemoteFiles() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        GitProtocol.state.setValue("src/before")
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: [])
        let root = fixture.store.root
        try await eventually { fixture.store.fileChanges[root.appending("src/before.txt")] == .modified }
        await fixture.connections.disconnect(fixture.host)
        try await eventually { !fixture.store.isConnected && fixture.store.fileChanges.isEmpty }
        await fixture.close()
    }

    @Test func sharesWatchBetweenListAndDiff() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        await fixture.connections.connect(fixture.host)
        let list = UUID()
        let diff = UUID()
        fixture.store.setUsage(id: list, listVisible: true, visibleDiffPaths: [])
        fixture.store.setUsage(id: diff, listVisible: false, visibleDiffPaths: ["file.txt"])
        try await eventually { fixture.store.diffs["file.txt"] != nil && fixture.store.changes.first != nil && GitProtocol.state.waitCount > 0 }
        fixture.store.setUsage(id: list, listVisible: false, visibleDiffPaths: [])
        GitProtocol.state.change(to: "after")
        try await eventually { fixture.store.diffs["file.txt"]?.content.after == "after" }
        #expect(GitProtocol.state.startCount == 1)
        fixture.store.setUsage(id: diff, listVisible: false, visibleDiffPaths: [])
        try await eventually { !fixture.store.isConnected }
        await fixture.close()
    }

    @Test func refreshesChangesAndVisibleDiffOnNotification() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: ["file.txt"])
        try await eventually { fixture.store.diffs["file.txt"]?.content.after == "before" && GitProtocol.state.waitCount > 0 }

        GitProtocol.state.change(to: "after")
        try await eventually { fixture.store.diffs["file.txt"]?.content.after == "after" }
        #expect(fixture.store.changes.first?.path == "after.txt")
        #expect(GitProtocol.state.startCount == 1)
        await fixture.close()
    }

    @Test func stopsWhileDisconnectedAndReloadsOnReconnect() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: [])
        try await eventually { fixture.store.changes.first?.path == "before.txt" }
        await fixture.connections.disconnect(fixture.host)
        try await eventually { !fixture.store.isConnected }
        let count = GitProtocol.state.startCount
        fixture.store.retry()
        try await Task.sleep(for: .milliseconds(100))
        #expect(GitProtocol.state.startCount == count)

        GitProtocol.state.setValue("after")
        await fixture.connections.connect(fixture.host)
        try await eventually { fixture.store.changes.first?.path == "after.txt" }
        #expect(GitProtocol.state.startCount == count + 1)
        await fixture.close()
    }

    @Test func discardsResultFromPreviousConnection() async throws {
        let fixture = try RemoteGitFixture()
        defer { fixture.store.stop() }
        GitProtocol.state.holdFirstChanges()
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: [])
        try await eventually { GitProtocol.state.hasHeldChanges }

        await fixture.connections.disconnect(fixture.host)
        try await eventually { !fixture.store.isConnected }
        GitProtocol.state.setValue("after")
        await fixture.connections.connect(fixture.host)
        try await eventually { fixture.store.changes.first?.path == "after.txt" }
        GitProtocol.state.releaseHeldChanges()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.store.changes.first?.path == "after.txt")
        await fixture.close()
    }

    @Test func retriesServerFailureOnlyWhileConnected() async throws {
        let fixture = try RemoteGitFixture(retryInterval: .milliseconds(100))
        defer { fixture.store.stop() }
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: [])
        try await eventually { fixture.store.changes.first?.path == "before.txt" && GitProtocol.state.waitCount > 0 }
        GitProtocol.state.setUnavailable(true)
        try await eventually { fixture.store.watchError != nil && GitProtocol.state.startCount >= 2 }
        GitProtocol.state.setValue("after")
        GitProtocol.state.setUnavailable(false)
        try await eventually { fixture.store.changes.first?.path == "after.txt" && fixture.store.watchError == nil }
        GitProtocol.state.setUnavailable(true)
        try await eventually { fixture.store.watchError != nil }
        await fixture.connections.disconnect(fixture.host)
        try await eventually { !fixture.store.isConnected }
        let count = GitProtocol.state.startCount
        try await Task.sleep(for: .milliseconds(250))
        #expect(GitProtocol.state.startCount == count)
        await fixture.close()
    }

    @Test func watchLimitRequiresManualRetry() async throws {
        let fixture = try RemoteGitFixture(retryInterval: .milliseconds(100))
        defer { fixture.store.stop() }
        GitProtocol.state.setLimitReached(true)
        await fixture.connections.connect(fixture.host)
        fixture.store.setUsage(listVisible: true, visibleDiffPaths: [])
        try await eventually { fixture.store.watchError != nil }
        try await Task.sleep(for: .milliseconds(250))
        #expect(GitProtocol.state.startCount == 1)
        GitProtocol.state.setLimitReached(false)
        fixture.store.retry()
        try await eventually { fixture.store.changes.first?.path == "before.txt" && fixture.store.watchError == nil }
        #expect(GitProtocol.state.startCount == 2)
        await fixture.close()
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class RemoteGitFixture {
    let container: ModelContainer
    let host: RemoteHost
    let connections: RemoteConnectionStore
    let servers: RemoteServerStore
    let session: URLSession
    let store: RemoteGitStore

    init(retryInterval: Duration = .seconds(10)) throws {
        GitProtocol.state.reset()
        container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        host = try HostStore(context: container.mainContext).addRemote(
            name: "fixture", basePath: "/workspace", hostname: "unused", user: "test", identityFile: "",
            devServerURL: "http://remote.test:8081", prodServerURL: "http://remote.test:8080"
        )
        connections = RemoteConnectionStore { host in
            let process = try SSH.Connection(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
            return SSHConnectionService(configuration: try SSH.Configuration(hostname: host.hostname, user: host.user),
                                        master: process, controlDirectory: try SSHConnectionService.makeControlDirectory())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitProtocol.self]
        session = URLSession(configuration: configuration)
        servers = RemoteServerStore(connections: connections, session: session, forward: { _, _, _ in 31001 },
                                    cancel: { _, _, _, _ in })
        store = RemoteGitStore(root: .remote(hostID: host.persistentModelID, path: "/workspace/repo"),
                               host: host, connections: connections, servers: servers, retryInterval: retryInterval)
    }

    func close() async {
        store.stop()
        let deadline = ContinuousClock.now + .seconds(3)
        while GitProtocol.state.stopCount < GitProtocol.state.startCount && .now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await servers.close()
        await connections.shutdown()
        session.invalidateAndCancel()
    }
}

private final class GitProtocol: URLProtocol, @unchecked Sendable {
    static let state = GitProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        switch (request.httpMethod, url.path) {
        case ("POST", "/git/watches"):
            Self.state.start(self)
        case ("GET", let path) where path.hasPrefix("/git/watches/"):
            Self.state.wait(self)
        case ("DELETE", let path) where path.hasPrefix("/git/watches/"):
            Self.state.stopped()
            reply(status: 204, body: "")
        case ("GET", "/git/changes"):
            Self.state.changes(self)
        case ("GET", "/git/diff"):
            let value = Self.state.currentValue
            reply(status: 200, body: "{\"path\":\"file.txt\",\"change\":\"modified\",\"content\":{\"type\":\"text\",\"before\":\"original\",\"after\":\"\(value)\"}}")
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
    }

    override func stopLoading() { Self.state.cancelWait(self) }

    func reply(status: Int, body: String) {
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
}

private final class GitProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "before"
    private var pending: GitProtocol?
    private var heldChanges: GitProtocol?
    private var holdChanges = false
    private var starts = 0
    private var stops = 0
    private var waits = 0
    private var revision = 0
    private var unavailable = false
    private var limitReached = false

    var currentValue: String { lock.withLock { value } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var waitCount: Int { lock.withLock { waits } }
    var hasHeldChanges: Bool { lock.withLock { heldChanges != nil } }

    func reset() {
        lock.withLock { value = "before"; pending = nil; heldChanges = nil; holdChanges = false; starts = 0; stops = 0; waits = 0; revision = 0; unavailable = false; limitReached = false }
    }

    func start(_ request: GitProtocol) {
        let state = lock.withLock { starts += 1; return (revision, unavailable, limitReached) }
        if state.1 { request.fail() }
        else if state.2 { request.reply(status: 503, body: "{\"error\":{\"code\":\"watch_limit_reached\",\"message\":\"limit\"}}") }
        else { request.reply(status: 200, body: "{\"id\":\"\(UUID().uuidString)\",\"revision\":\(state.0)}") }
    }

    func wait(_ request: GitProtocol) {
        let shouldFail = lock.withLock { waits += 1; if !unavailable { pending = request }; return unavailable }
        if shouldFail { request.fail() }
    }
    func stopped() { lock.withLock { stops += 1 } }
    func cancelWait(_ request: GitProtocol) { lock.withLock { if pending === request { pending = nil } } }
    func setValue(_ value: String) { lock.withLock { self.value = value } }
    func setLimitReached(_ value: Bool) { lock.withLock { limitReached = value } }
    func setUnavailable(_ value: Bool) {
        let request = lock.withLock { unavailable = value; let request = value ? pending : nil; if value { pending = nil }; return request }
        request?.fail()
    }
    func holdFirstChanges() { lock.withLock { holdChanges = true } }

    func changes(_ request: GitProtocol) {
        let value: String? = lock.withLock {
            if holdChanges { holdChanges = false; heldChanges = request; return nil }
            return self.value
        }
        if let value { replyChanges(request, value: value) }
    }

    func releaseHeldChanges() {
        let request = lock.withLock { let request = heldChanges; heldChanges = nil; return request }
        if let request { replyChanges(request, value: "before") }
    }

    func change(to value: String) {
        let result: (GitProtocol?, Int) = lock.withLock {
            self.value = value
            revision += 1
            let request = pending
            pending = nil
            return (request, revision)
        }
        result.0?.reply(status: 200, body: "{\"revision\":\(result.1)}")
    }

    private func replyChanges(_ request: GitProtocol, value: String) {
        request.reply(status: 200, body: "[{\"path\":\"\(value).txt\",\"change\":\"modified\"}]")
    }
}
