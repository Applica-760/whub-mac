import SwiftUI
import SwiftData
import WhubCore

struct ServerWidget: View {
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @EnvironmentObject private var servers: RemoteServerStore
    @StateObject private var store = ServerStore()

    private var remoteHosts: [RemoteHost] { hosts.compactMap { $0 as? RemoteHost } }

    var body: some View {
        WidgetFrame {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ServerPanel(store: store)
                    Divider()
                    ServerLogView(store: store)
                        .frame(width: 320)
                }
                .frame(height: 240, alignment: .top)
                .padding(14)
            }
            .font(.body)
            .controlSize(.small)
        } header: {
            HStack(spacing: 8) {
                Label("Server", systemImage: "server.rack")
                    .font(.subheadline.bold())
                Picker("Host", selection: $store.hostID) {
                    Text("ホストを選択").tag(nil as PersistentIdentifier?)
                    ForEach(store.hosts) { host in
                        Text(host.name).tag(Optional(host.persistentModelID))
                    }
                }
                .frame(width: 160)
                .controlSize(.small)
                .disabled(store.isBusy)
                Button {
                    Task { await store.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Dev・Prodをリロード")
                .accessibilityLabel("Dev・Prodをリロード")
                .disabled(store.isBusy || store.host == nil)
                Group {
                    if let checkedAt = store.checkedAt {
                        Text("状態取得 \(checkedAt.formatted(date: .omitted, time: .standard))")
                    } else {
                        Text("状態未取得")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { store.configure(hosts: remoteHosts, servers: servers) }
        .onChange(of: remoteHosts.map(\.persistentModelID)) { _, _ in
            store.configure(hosts: remoteHosts, servers: servers)
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
