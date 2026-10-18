import SwiftUI

struct ServerWidget: View {
    @StateObject private var store = ServerStore(
        backend: MockServerBackend(), hosts: MockServerBackend.hosts
    )

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
        .frame(maxWidth: 1090)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
