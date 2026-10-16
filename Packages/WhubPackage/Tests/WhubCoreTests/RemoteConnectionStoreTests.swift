// 検証する内容:
// - 接続操作を重ねても、同じホストの共通SSH接続は1つである。
// - 接続中に切断すると、遅れて成功・失敗した結果が接続状態を復活・上書きしない。
// - 要求を送っていない時のプロセス終了も通知され、接続済みのまま残らない。
// - 通知購読前に切断していた場合も検知し、アプリ終了時は接続中の処理も片付ける。
// - 保存済みHostの接続先変更・削除で旧接続を無効化し、表示名変更と入力エラーでは維持する。
// 限界: ローカルのプロセスで接続の所有・状態管理を検証する。実SSH認証は対象外。ホバー・フォーカス・見た目はGUI確認が必要。
import SwiftData
import Foundation
import Testing
@testable import WhubCore

@Suite @MainActor
struct RemoteConnectionStoreTests {
    private func host(_ name: String = "test") -> RemoteHost {
        RemoteHost(name: name, basePath: "/", hostname: "unused", user: "test", identityFile: "")
    }

    private func localConnection() throws -> (SSH.Connection, SSHConnectionService) {
        let process = try SSH.Connection(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let connection = SSHConnectionService(
            configuration: try SSH.Configuration(hostname: "unused", user: "test"),
            master: process, controlDirectory: try SSHConnectionService.makeControlDirectory()
        )
        return (process, connection)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func hostChangesInvalidateOnlyAffectedConnections() async throws {
        let container = try ModelContainer(
            for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.autosaveEnabled = false
        let hosts = HostStore(context: context)
        let host = try hosts.addRemote(name: "test", basePath: "/", hostname: "old", user: "test", identityFile: "")
        var processes: [SSH.Connection] = []
        var destinations: [String] = []
        let store = RemoteConnectionStore { host in
            destinations.append(host.hostname)
            let (connection, session) = try localConnection()
            processes.append(connection)
            return session
        }
        await store.connect(host)
        let original = try #require(store.connection(for: host))
        try hosts.editRemote(host, name: "renamed", basePath: "/", hostname: "old", user: "test", port: 22, identityFile: "")
        #expect(store.connection(for: host) === original)
        #expect(throws: (any Error).self) {
            try hosts.editRemote(host, name: "renamed", basePath: "/", hostname: "", user: "test", port: 22, identityFile: "")
        }
        #expect(store.connection(for: host) === original)

        try hosts.editRemote(host, name: "renamed", basePath: "/", hostname: "new", user: "test", port: 22, identityFile: "")
        #expect(store.connection(for: host) == nil)
        #expect(store.state(for: host) == .disconnecting)
        await store.connect(host)
        #expect(destinations == ["old"])
        await store.disconnect(host)
        #expect(processes[0].process.isRunning == false)
        await store.connect(host)
        #expect(destinations == ["old", "new"])

        let id = host.persistentModelID
        try hosts.delete(host)
        #expect(store.states[id] == .disconnecting)
        #expect(try hosts.fetchHosts().isEmpty)
        try await eventually { store.states[id] == .disconnected }
        #expect(processes.allSatisfy { !$0.process.isRunning })
        await store.shutdown()
    }

    @Test func repeatedConnectReusesOneProcess() async throws {
        let host = host()
        let gate = Gate()
        var starts = 0
        var process: SSH.Connection?
        let store = RemoteConnectionStore { _ in
            starts += 1
            let (connection, session) = try localConnection()
            process = connection
            await gate.wait()
            return session
        }
        let first = Task { await store.connect(host) }
        try await eventually { gate.isWaiting }
        await store.connect(host)
        #expect(starts == 1)
        #expect(store.state(for: host) == .connecting)
        gate.release()
        await first.value
        let session = try #require(store.connection(for: host))
        #expect(session.isConnected)
        await store.connect(host)
        #expect(starts == 1)
        #expect(store.connection(for: host) === session)
        #expect(session.isConnected)
        await store.disconnect(host)
        #expect(store.state(for: host) == .disconnected)
        #expect(process?.process.isRunning == false)
    }

    @Test(arguments: [true, false])
    func cancelledAttemptCannotReviveConnection(succeeds: Bool) async throws {
        let host = host()
        let gate = Gate()
        var starts = 0
        var oldProcess: SSH.Connection?
        let store = RemoteConnectionStore { _ in
            starts += 1
            let (connection, session) = try localConnection()
            if starts == 1 {
                oldProcess = connection
                // Deliberately ignore cancellation to simulate a late connection completion.
                await gate.wait()
                if !succeeds {
                    await session.close()
                    throw SSHError.timedOut
                }
            }
            return session
        }
        let attempt = Task { await store.connect(host) }
        try await eventually { gate.isWaiting }
        let disconnect = Task { await store.disconnect(host) }
        try await eventually { store.state(for: host) == .disconnecting }
        await store.connect(host)
        #expect(starts == 1)
        gate.release()
        await disconnect.value
        await attempt.value
        #expect(store.state(for: host) == .disconnected)
        #expect(store.connection(for: host) == nil)
        #expect(oldProcess?.process.isRunning == false)
        await store.connect(host)
        #expect(starts == 2)
        #expect(store.state(for: host) == .connected)
        await store.disconnect(host)
    }

    @Test func idleDisconnectUpdatesState() async throws {
        let host = host()
        let (connection, session) = try localConnection()
        let store = RemoteConnectionStore { _ in session }
        await store.connect(host)
        #expect(store.state(for: host) == .connected)
        connection.process.terminate()
        try await eventually {
            if case .failed = store.state(for: host) { return true }
            return false
        }
        #expect(store.connection(for: host) == nil)
        #expect(session.disconnectionError != nil)
        await session.close()
    }

    @Test func disconnectBeforeObservationIsNotLost() async throws {
        let host = host()
        let (_, session) = try localConnection()
        await session.close()
        let store = RemoteConnectionStore { _ in session }
        await store.connect(host)
        #expect(store.state(for: host) == .failed(SSHError.disconnected.localizedDescription))
        #expect(store.connection(for: host) == nil)
    }

    @Test func shutdownClosesActiveAndPendingConnections() async throws {
        let active = host("active"), pending = host("pending"), blocked = host("blocked")
        let gate = Gate()
        var processes: [SSH.Connection] = []
        let store = RemoteConnectionStore { host in
            let (connection, session) = try localConnection()
            processes.append(connection)
            if host.name == "pending" { await gate.wait() }
            return session
        }
        await store.connect(active)
        let attempt = Task { await store.connect(pending) }
        try await eventually { gate.isWaiting }
        let shutdown = Task { await store.shutdown() }
        try await eventually { store.state(for: pending) == .disconnecting }
        await store.connect(blocked)
        #expect(processes.count == 2)
        gate.release()
        await shutdown.value
        await attempt.value
        #expect(store.state(for: active) == .disconnected)
        #expect(store.state(for: pending) == .disconnected)
        #expect(processes.allSatisfy { !$0.process.isRunning })
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
