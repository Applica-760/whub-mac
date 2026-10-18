import SwiftUI

struct ServerWidget: View {
    @StateObject private var store = ServerStore(
        backend: MockServerBackend(), hosts: MockServerBackend.hosts
    )

    var body: some View {
        WidgetFrame {
            HStack(alignment: .top, spacing: 12) {
                ServerPanel(store: store, environment: .dev)
                Divider()
                ServerPanel(store: store, environment: .prod)
                Divider()
                ServerLogView(store: store)
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
            .font(.caption)
            .controlSize(.mini)
            .padding(10)
        } header: {
            HStack(spacing: 8) {
                Label("Server", systemImage: "server.rack")
                    .font(.subheadline.bold())
                Text("Mock").font(.caption2).foregroundStyle(.secondary)
                Picker("Host", selection: $store.hostID) {
                    ForEach(store.hosts) { host in
                        Text(host.name).tag(host.id)
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
                .disabled(store.isBusy)
                Spacer()
            }
        }
    }
}
