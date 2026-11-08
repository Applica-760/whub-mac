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

    @Test func filesStoresUseTheSharedHTTPClient() async throws {
        let fixture = try Fixture()
        await fixture.connections.connect(fixture.host)
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        var forwards = 0
        let servers = RemoteServerStore(connections: fixture.connections, session: session, forward: { _, _, _ in
            forwards += 1
            return 31001
        }, cancel: { _, _, _, _ in })
        #if DEBUG
        #expect(RemoteServerStore.currentEnvironment == .dev)
        #else
        #expect(RemoteServerStore.currentEnvironment == .prod)
        #endif
        let project = try ProjectStore(context: fixture.container.mainContext).add(name: "demo", gitURL: nil, host: fixture.host)
        let workspace = RemoteWorkspaceStore()
        workspace.update(hosts: [fixture.host], connections: fixture.connections, servers: servers, refreshID: 0,
                         context: fixture.container.mainContext, projects: [project])
        try await eventually { workspace.states[fixture.host.persistentModelID] == .loaded }
        let sources = RemoteWorkspaceStore.connectedSources(hosts: [fixture.host], projects: [project], connections: fixture.connections)
        let root = FileLocation.remote(hostID: fixture.host.persistentModelID, path: "/workspace/projects/demo")
        #expect(workspace.entries(for: sources) == [sources[0].baseLocation, root])
        let tree = RemoteTreeStore()
        tree.update(location: root, hosts: [fixture.host], connections: fixture.connections, servers: servers, refreshID: 0)
        try await eventually { tree.states[""] == .loaded }
        #expect(tree.rootItems.map(\.location) == [root.appending("hello.txt")])
        let editor = RemoteEditorStore()
        let file = root.appending("hello.txt")
        editor.load(file, root: root, hosts: [fixture.host], connections: fixture.connections, servers: servers)
        try await eventually {
            if case .loaded = editor.states[file] { return true }
            return false
        }
        #expect(forwards == 1)
        await fixture.connections.disconnect(fixture.host)
        try await eventually {
            if case .disconnected = editor.states[file] { return true }
            return false
        }
        editor.close(file)
        tree.stop()
        workspace.stop()
        await servers.close()
        await fixture.connections.shutdown()
    }

    @Test func remoteFileIOPassesArgumentsAndRejectsChangedConnections() async throws {
        for change in ["none", "connection", "url"] {
            for operation in ["read", "read-image", "write"] {
                let fixture = try Fixture()
                await fixture.connections.connect(fixture.host)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [FileIOProtocol.self]
                let session = URLSession(configuration: configuration)
                let servers = RemoteServerStore(connections: fixture.connections, session: session,
                                                forward: { _, _, _ in 31001 }, cancel: { _, _, _, _ in })
                let io = RemoteFileIO(host: fixture.host, connections: fixture.connections, servers: servers)
                let originalConnection = try #require(io.connectionID)
                FileIOProtocol.respond = { request in
                    let url = try #require(request.url)
                    #expect(url.path == "/api/files/" + operation)
                    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    #expect(query.first { $0.name == "root" }?.value == "/workspace")
                    #expect(query.first { $0.name == "path" }?.value == "sample.txt")
                    #expect(request.httpMethod == (operation == "write" ? "PUT" : "GET"))
                    if operation == "write" {
                        var data = request.httpBody ?? Data()
                        if let stream = request.httpBodyStream {
                            stream.open()
                            defer { stream.close() }
                            var buffer = [UInt8](repeating: 0, count: 1024)
                            while true {
                                let count = stream.read(&buffer, maxLength: buffer.count)
                                guard count >= 0 else { throw URLError(.cannotDecodeContentData) }
                                if count == 0 { break }
                                data.append(contentsOf: buffer.prefix(count))
                            }
                        }
                        let body = try JSONDecoder().decode([String: String].self, from: data)
                        #expect(body == ["expectedText": "before", "text": "after"])
                    }
                    if change == "connection" {
                        await fixture.connections.disconnect(fixture.host)
                        await fixture.connections.connect(fixture.host)
                        #expect(io.connectionID != originalConnection)
                    } else if change == "url" {
                        fixture.host.devServerURL = "http://remote.test:8082/api/"
                        fixture.host.prodServerURL = "http://remote.test:8082/api/"
                    }
                    return operation == "read-image" ? Data([1, 2, 3]) : Data(#"{"text":"after"}"#.utf8)
                }
                do {
                    switch operation {
                    case "read":
                        #expect(try await io.readText(root: "/workspace", path: "sample.txt") == "after")
                    case "read-image":
                        #expect(try await io.readImage(root: "/workspace", path: "sample.txt") == Data([1, 2, 3]))
                    default:
                        #expect(try await io.writeText(root: "/workspace", path: "sample.txt",
                                                      expectedText: "before", text: "after") == "after")
                    }
                    #expect(change == "none", "Accepted a response after changing \(change) during \(operation)")
                } catch SSHError.disconnected {
                    #expect(change != "none")
                } catch {
                    Issue.record("Unexpected error for \(operation), \(change): \(error)")
                }
                FileIOProtocol.respond = nil
                await servers.close()
                await fixture.connections.shutdown()
                session.invalidateAndCancel()
            }
        }
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
              ["/api/ping", "/api/files/list", "/api/files/read"].contains(url.path),
              [31001, 31002].contains(url.port ?? 0) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let root = query.first { $0.name == "root" }?.value
        let path = query.first { $0.name == "path" }?.value
        let body: String
        switch url.path {
        case "/api/files/list":
            guard path == "", let root else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            switch root {
            case "/workspace/projects": body = #"[{"name":"demo","kind":"directory"}]"#
            case "/workspace/worktrees": body = "[]"
            case "/workspace/projects/demo": body = #"[{"name":"hello.txt","kind":"file"}]"#
            default:
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
        case "/api/files/read":
            guard root == "/workspace/projects/demo", path == "hello.txt" else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            body = #"{"text":"hello over HTTP"}"#
        default: body = "pong"
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FileIOProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var respond: ((URLRequest) async throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try #require(Self.respond)
                let data = try await handler(request)
                let url = try #require(request.url)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}
