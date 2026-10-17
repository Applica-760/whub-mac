import SwiftData
import SwiftUI
import WhubCore

struct RemoteConnectionToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            RemoteConnectionToolbarView()
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.fixed, placement: .primaryAction)
    }
}

struct RemoteConnectionToolbarView: View {
    @Query(sort: \WhubCore.Host.name) private var allHosts: [WhubCore.Host]
    @EnvironmentObject private var connections: RemoteConnectionStore
    @State private var isPresented = false

    private var hostMenu: HostMenu {
        HostMenu(connections: connections)
    }

    private var hosts: [RemoteHost] {
        hostMenu.hosts(from: allHosts)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "network")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    badge(connected: hosts.contains { connections.state(for: $0) == .connected })
                        .offset(x: -2, y: -2)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("リモート接続")
        .accessibilityValue(hosts.contains { connections.state(for: $0) == .connected } ? "接続済み" : "未接続")
        .help("リモート接続")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(spacing: 4) {
                ForEach(hosts) { host in
                    hostRow(host)
                }
            }
            .padding(8)
            .frame(minWidth: 160)
        }
    }

    private func hostRow(_ host: RemoteHost) -> some View {
        Button {
            isPresented = false
            Task { await hostMenu.perform(for: host) }
        } label: {
            HStack(spacing: 12) {
                Text(host.name)
                Spacer(minLength: 12)
                if connections.state(for: host) == .connecting || connections.state(for: host) == .disconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    badge(connected: connections.state(for: host) == .connected)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!hostMenu.isEnabled(for: host))
        .accessibilityLabel(hostMenu.title(for: host))
        .accessibilityValue(hostMenu.status(for: host))
        .help("\(hostMenu.title(for: host)) — \(hostMenu.status(for: host))")
    }

    private func badge(connected: Bool) -> some View {
        Circle()
            .fill(connected ? Color.green : Color.red)
            .frame(width: 8, height: 8)
    }
}

extension RemoteConnectionToolbarView {
    @MainActor
    struct HostMenu {
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
}
