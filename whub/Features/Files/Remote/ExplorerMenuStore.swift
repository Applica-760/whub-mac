import WhubCore

@MainActor
struct ExplorerMenuStore {
    let connections: RemoteConnectionStore

    func hosts(from hosts: [WhubCore.Host]) -> [RemoteHost] {
        hosts.compactMap { $0 as? RemoteHost }
    }

    func title(for host: RemoteHost) -> String {
        let action: String = switch connections.state(for: host) {
        case .disconnected, .failed: "接続"
        case .connecting: "キャンセル"
        case .connected: "切断"
        case .disconnecting: "切断中"
        }
        return "\(host.name)を\(action)"
    }

    func status(for host: RemoteHost) -> String {
        switch connections.state(for: host) {
        case .disconnected: "未接続"
        case .connecting: "接続中…"
        case .connected: "接続済み"
        case .disconnecting: "切断中…"
        case let .failed(message): message
        }
    }

    func isEnabled(for host: RemoteHost) -> Bool {
        connections.state(for: host) != .disconnecting
    }

    func perform(for host: RemoteHost) async {
        switch connections.state(for: host) {
        case .connecting, .connected: await connections.disconnect(host)
        case .disconnected, .failed: await connections.connect(host)
        case .disconnecting: break
        }
    }
}
