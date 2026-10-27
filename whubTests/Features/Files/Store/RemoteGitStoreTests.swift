// テスト一覧:
// - RemoteGitStoreTests.refreshesChangesAndVisibleDiffOnNotification(): [RGITSTORE-F-001]
// - RemoteGitStoreTests.stopsWhileDisconnectedAndReloadsOnReconnect(): [RGITSTORE-F-002]
// - RemoteGitStoreTests.discardsResultFromPreviousConnection(): [RGITSTORE-F-003]

import Foundation
import SwiftData
import Testing
import WhubClient
@testable import WhubCore
@testable import whub

@Suite(.serialized) @MainActor
struct RemoteGitStoreTests {
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

    init() throws {
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
                               host: host, connections: connections, servers: servers)
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

    var currentValue: String { lock.withLock { value } }
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var waitCount: Int { lock.withLock { waits } }
    var hasHeldChanges: Bool { lock.withLock { heldChanges != nil } }

    func reset() {
        lock.withLock { value = "before"; pending = nil; heldChanges = nil; holdChanges = false; starts = 0; stops = 0; waits = 0; revision = 0 }
    }

    func start(_ request: GitProtocol) {
        let current = lock.withLock { starts += 1; return revision }
        request.reply(status: 200, body: "{\"id\":\"\(UUID().uuidString)\",\"revision\":\(current)}")
    }

    func wait(_ request: GitProtocol) { lock.withLock { waits += 1; pending = request } }
    func stopped() { lock.withLock { stops += 1 } }
    func cancelWait(_ request: GitProtocol) { lock.withLock { if pending === request { pending = nil } } }
    func setValue(_ value: String) { lock.withLock { self.value = value } }
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
