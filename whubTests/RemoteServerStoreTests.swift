import Foundation
import SwiftData
import Testing
import WhubClient
@testable import WhubCore
@testable import whub

@Suite @MainActor
struct RemoteServerStoreTests {
    @Test func sharesPreparationAndSeparatesEnvironments() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        let gate = Gate()
        var forwards: [String] = []
        var cancelled: [Int] = []
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let servers = RemoteServerStore(connections: fixture.connections, session: session, forward: { _, host, port in
            forwards.append("\(host):\(port)")
            if forwards.count == 1 { await gate.wait() }
            return port == 8081 ? 31001 : 31002
        }, cancel: { _, port, _, _ in cancelled.append(port) })

        let first = Task { try await servers.client(for: fixture.host, environment: .dev) }
        try await eventually { gate.isWaiting }
        let second = Task { try await servers.client(for: fixture.host, environment: .dev) }
        gate.release()
        try await first.value.ping()
        try await second.value.ping()
        let reused = try await servers.client(for: fixture.host, environment: .dev)
        try await reused.ping()
        #expect(forwards == ["remote.test:8081"])
        let prod = try await servers.client(for: fixture.host, environment: .prod)
        try await prod.ping()
        #expect(forwards == ["remote.test:8081", "remote.test:8080"])

        await servers.close()
        #expect(Set(cancelled) == [31001, 31002])
        #expect(fixture.connections.connection(for: fixture.host)?.isConnected == true)
        await fixture.connections.shutdown()
    }

    @Test func rejectsMissingAndNonHTTPSettingsBeforeForwarding() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        let servers = RemoteServerStore(connections: fixture.connections, forward: { _, _, _ in
            Issue.record("Invalid URL reached SSH forwarding")
            throw SSHError.invalidForwarding
        })
        for rawValue in [nil, "", "https://remote.test", "http://user@remote.test", "http://remote.test?q=1",
                         "http://remote.test#fragment", "http://remote.test:65536", "not a URL"] as [String?] {
            fixture.host.devServerURL = rawValue
            do {
                _ = try await servers.client(for: fixture.host, environment: .dev)
                Issue.record("Accepted invalid server URL")
            } catch is RemoteServerError {}
        }
        await servers.close()
        await fixture.connections.shutdown()
    }

    @Test func URLChangesDiscardRoutesAndReconnectCreatesANewRoute() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        let oldConnection = try #require(fixture.connections.connection(for: fixture.host))
        var forwardedPorts: [Int] = []
        var cancelled: [Int] = []
        let servers = RemoteServerStore(connections: fixture.connections, forward: { _, _, port in
            forwardedPorts.append(port)
            return 31000 + forwardedPorts.count
        }, cancel: { _, port, _, _ in cancelled.append(port) })
        _ = try await servers.client(for: fixture.host, environment: .dev)

        let host = fixture.host
        try HostStore(context: fixture.container.mainContext).editRemote(
            host, name: host.name, basePath: host.basePath, hostname: host.hostname, user: host.user,
            port: host.port, identityFile: host.identityFile, devServerURL: "http://remote.test:8082/api/"
        )
        try await eventually { fixture.connections.state(for: host) == .disconnected }
        try await eventually { cancelled.contains(31001) }
        await fixture.connections.connect(host)
        #expect(fixture.connections.connection(for: host) !== oldConnection)
        _ = try await servers.client(for: host, environment: .dev)
        #expect(forwardedPorts == [8081, 8082])
        await servers.close()
        #expect(Set(cancelled) == [31001, 31002])
        await fixture.connections.shutdown()
    }

    @Test func lateForwardingAfterDisconnectIsCancelledAndCannotBeReused() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        let gate = Gate()
        var forwards = 0
        var cancelled: [Int] = []
        let servers = RemoteServerStore(connections: fixture.connections, forward: { _, _, _ in
            forwards += 1
            let port = 31000 + forwards
            if forwards == 1 { await gate.wait() }
            return port
        }, cancel: { _, port, _, _ in cancelled.append(port) })
        let pending = Task { try await servers.client(for: fixture.host, environment: .dev) }
        try await eventually { gate.isWaiting }
        await fixture.connections.disconnect(fixture.host)
        gate.release()
        do { _ = try await pending.value; Issue.record("Returned a stale client") }
        catch is CancellationError {}
        #expect(cancelled == [31001])
        await fixture.connections.connect(fixture.host)
        _ = try await servers.client(for: fixture.host, environment: .dev)
        #expect(forwards == 2)
        await servers.close()
        #expect(Set(cancelled) == [31001, 31002])
        await fixture.connections.shutdown()
    }

    @Test func forwardingFailureCanBeRetried() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        var attempts = 0
        let servers = RemoteServerStore(connections: fixture.connections, forward: { _, _, _ in
            attempts += 1
            if attempts == 1 { throw SSHError.operationFailed("fixture") }
            return 31001
        }, cancel: { _, _, _, _ in })
        do { _ = try await servers.client(for: fixture.host, environment: .dev); Issue.record("Expected failure") }
        catch SSHError.operationFailed {}
        _ = try await servers.client(for: fixture.host, environment: .dev)
        #expect(attempts == 2)
        await servers.close()
        await fixture.connections.shutdown()
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PingProtocol.self]
        return URLSession(configuration: configuration)
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
private struct Fixture {
    let container: ModelContainer
    let host: RemoteHost
    let connections: RemoteConnectionStore

    init() throws {
        container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        host = try HostStore(context: container.mainContext).addRemote(
            name: "fixture", basePath: "/workspace", hostname: "unused", user: "test", identityFile: "",
            devServerURL: "http://remote.test:8081/api/", prodServerURL: "http://remote.test:8080/api/"
        )
        connections = RemoteConnectionStore { host in
            let process = try SSH.Connection(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
            return SSHConnectionService(
                configuration: try SSH.Configuration(hostname: host.hostname, user: host.user),
                master: process, controlDirectory: try SSHConnectionService.makeControlDirectory()
            )
        }
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class PingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.scheme == "http", url.host == "127.0.0.1",
              url.path == "/api/ping", [31001, 31002].contains(url.port ?? 0) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("pong".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
