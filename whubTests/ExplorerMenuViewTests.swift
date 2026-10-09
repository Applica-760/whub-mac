import Foundation
import SwiftData
import Testing
@testable import WhubCore
@testable import whub

@Suite @MainActor
struct ExplorerMenuViewTests {
    private struct ConnectionFailure: LocalizedError {
        var errorDescription: String? { "接続失敗" }
    }

    @Test func filtersLocalHostsAndRetriesFailures() async {
        let host = RemoteHost(name: "server", basePath: "/", hostname: "unused", user: "test", identityFile: "")
        let local = LocalHost(name: "local", basePath: "/")
        var attempts = 0
        let connections = RemoteConnectionStore(open: { _ in
            attempts += 1
            throw ConnectionFailure()
        })
        let menu = ExplorerMenuView.HostMenu(connections: connections)
        #expect(menu.hosts(from: [local, host]).map(\.persistentModelID) == [host.persistentModelID])
        #expect(menu.title(for: host) == "serverを接続")
        await menu.perform(for: host)
        #expect(menu.status(for: host) == "接続失敗")
        #expect(menu.isEnabled(for: host))
        await menu.perform(for: host)
        #expect(attempts == 2)
    }

    @Test func actionUsesCurrentConnectionStateToCancel() async throws {
        let host = RemoteHost(name: "server", basePath: "/", hostname: "unused", user: "test", identityFile: "")
        let connections = RemoteConnectionStore(open: { _ in
            try await Task.sleep(for: .seconds(30))
            throw ConnectionFailure()
        })
        let menu = ExplorerMenuView.HostMenu(connections: connections)
        let connecting = Task { await menu.perform(for: host) }
        defer { connecting.cancel() }
        let deadline = ContinuousClock.now + .seconds(3)
        while connections.state(for: host) != .connecting {
            guard ContinuousClock.now < deadline else {
                Issue.record("接続開始を確認できませんでした")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(menu.title(for: host) == "serverをキャンセル")
        await menu.perform(for: host)
        await connecting.value
        #expect(connections.state(for: host) == .disconnected)
        #expect(menu.status(for: host) == "未接続")
    }
}
