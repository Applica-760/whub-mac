import SwiftData
import SwiftUI
import WhubCore

struct ExplorerActionsView: View {
    let availableWidth: CGFloat
    let canRefresh: Bool
    let refresh: () -> Void
    @Query(sort: \WhubCore.Host.name) private var allHosts: [WhubCore.Host]
    @EnvironmentObject private var connections: RemoteConnectionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?
    @FocusState private var triggerFocused: Bool
    @Namespace private var glassNamespace

    private var hosts: [RemoteHost] {
        allHosts.compactMap { $0 as? RemoteHost }
    }

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(alignment: .trailing, spacing: 12) {
                trigger
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("trigger", in: glassNamespace)
                    .focused($triggerFocused)

                if isPresented {
                    HStack(spacing: 12) {
                        Text("リロード")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                        roundButton("リロード", icon: "arrow.clockwise") {
                            refresh()
                            dismiss()
                        }
                        .disabled(!canRefresh)
                        .glassEffectID("refresh", in: glassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                    }
                    .transition(.identity)

                    ForEach(hosts) { host in
                        hostRow(host)
                            .transition(.identity)
                    }
                }
            }
            .frame(width: isPresented ? availableWidth : 36, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover {
                hovered = $0
                updateHover()
            }
        }
        .background {
            if isPresented {
                Rectangle()
                    .fill(.regularMaterial)
                    .overlay { Color.gray.opacity(0.3) }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.08),
                                .init(color: .black, location: 0.92),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                    }
                    .padding(-24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: 36, height: 36, alignment: .topTrailing)
        .onExitCommand { dismiss() }
        .onDisappear { dismiss() }
    }

    @ViewBuilder private var trigger: some View {
        if isPresented {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .accessibilityLabel("操作ボタンを閉じる")
            .keyboardShortcut(.cancelAction)
        } else {
            Button {
                hoverTask?.cancel()
                setPresented(true)
                triggerFocused = true
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Explorerの操作")
        }
    }

    private func roundButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(title)
        .help(title)
    }

    private func hostRow(_ host: RemoteHost) -> some View {
        let state = connections.state(for: host)
        let title = "\(host.name)を\(actionTitle(state))"
        return HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(title).lineLimit(1)
                Text(statusTitle(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help("\(title) — \(statusTitle(state))")
            .transition(.opacity)

            roundButton(title, icon: "network") {
                Task {
                    switch state {
                    case .connecting, .connected: await connections.disconnect(host)
                    case .disconnected, .failed: await connections.connect(host)
                    case .disconnecting: break
                    }
                }
            }
            .disabled(state == .disconnecting)
            .glassEffectID(host.persistentModelID, in: glassNamespace)
            .glassEffectTransition(.matchedGeometry)
        }
    }

    private func actionTitle(_ state: RemoteConnectionStore.State) -> String {
        switch state {
        case .disconnected, .failed: "接続"
        case .connecting: "キャンセル"
        case .connected: "切断"
        case .disconnecting: "切断中"
        }
    }

    private func statusTitle(_ state: RemoteConnectionStore.State) -> String {
        switch state {
        case .disconnected: "未接続"
        case .connecting: "接続中…"
        case .connected: "接続済み"
        case .disconnecting: "切断中…"
        case let .failed(message): message
        }
    }

    private func updateHover() {
        hoverTask?.cancel()
        hoverTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            setPresented(hovered)
        }
    }

    private func setPresented(_ presented: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
            isPresented = presented
        }
    }

    private func dismiss() {
        hoverTask?.cancel()
        setPresented(false)
    }
}
