import SwiftUI

struct ServerPanel: View {
    @ObservedObject var store: ServerStore
    let environment: ServerEnvironment
    @State private var confirmation: ServerAction?

    private var state: ServerPanelState { store.state(environment) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(environment.rawValue).font(.subheadline.bold())
            Text(store.host?.url(for: environment) ?? "URL未設定")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.host?.url(for: environment) ?? "URL未設定")
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Text("状態")
                    Text(state.checkedAt == nil ? "未確認" : "最終確認：応答あり")
                        .foregroundStyle(.secondary)
                    Button("再起動") { confirmation = .restart }
                        .frame(width: 48)
                        .disabled(state.checkedAt == nil)
                }
                GridRow {
                    Text("稼働")
                    Text(state.running?.label ?? "未取得")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
                GridRow {
                    Text("取得")
                    Group {
                        if let date = state.fetchedAt {
                            Text(date, format: .dateTime.hour().minute().second())
                        } else {
                            Text(environment == .dev ? "未取得" : "Build時にFetch")
                        }
                    }
                    .foregroundStyle(.secondary)
                    if environment == .dev {
                        actionButton(.fetch)
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
                GridRow {
                    Text("commit")
                    if environment == .dev {
                        Picker("commit", selection: selection(\.selectedCommit)) {
                            Text("選択").tag("")
                            ForEach(state.commits) { commit in Text(commit.label).tag(commit.id) }
                        }
                        .labelsHidden()
                        .frame(minWidth: 0, maxWidth: .infinity)
                    } else {
                        Text("最新main（自動）").foregroundStyle(.secondary)
                    }
                    actionButton(.build)
                        .disabled(environment == .dev && state.selectedCommit.isEmpty)
                }
                GridRow {
                    Text("ビルド")
                    Picker("ビルド", selection: selection(\.selectedBuild)) {
                        Text(state.builds.isEmpty ? "ビルドなし" : "選択").tag("")
                        ForEach(state.builds) { build in Text(build.label).tag(build.id) }
                    }
                    .labelsHidden()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    Button("Apply") { confirmation = .apply }
                        .frame(width: 48)
                        .disabled(state.selectedBuild.isEmpty || state.checkedAt == nil)
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(store.isBusy || store.host == nil)
            HStack(spacing: 4) {
                Text("確認")
                if let checkedAt = state.checkedAt {
                    Text(checkedAt, format: .dateTime.hour().minute().second())
                } else {
                    Text("未取得 · 上のリロードで確認")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            confirmation == .apply ? "選択したビルドをApplyしますか？" : "現在の稼働版を再起動しますか？",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if let action = confirmation {
                Button(action.rawValue) {
                    Task { await store.run(action, environment: environment) }
                    confirmation = nil
                }
            }
            Button("キャンセル", role: .cancel) { confirmation = nil }
        } message: {
            let build = state.builds.first { $0.id == state.selectedBuild }
            Text("\(store.host?.name ?? "") / \(environment.rawValue)\n\(store.host?.url(for: environment) ?? "")\n\(confirmation == .apply ? build?.label ?? "" : state.running?.label ?? "")\nMock：サンプルデータだけが変化します。")
        }
    }

    private func actionButton(_ action: ServerAction) -> some View {
        Button(action.rawValue) {
            Task { await store.run(action, environment: environment) }
        }
        .frame(width: 48)
    }

    private func selection(_ field: WritableKeyPath<ServerPanelState, String>) -> Binding<String> {
        Binding(
            get: { state[keyPath: field] },
            set: { store.select($0, field: field, environment: environment) }
        )
    }
}
