import SwiftUI

struct ServerPanel: View {
    private enum Row: String, CaseIterable {
        case status = "状態", running = "稼働", fetch = "取得", commit = "commit", build = "ビルド"
    }

    @ObservedObject var store: ServerStore
    @State private var confirmation: (action: ServerAction, environment: ServerEnvironment)?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Dev").font(.title3.bold()).padding(.vertical, 5).gridCellColumns(2)
                Color.clear.frame(width: 1).gridCellUnsizedAxes(.vertical)
                Text("Prod").font(.title3.bold()).padding(.vertical, 5).gridCellColumns(2)
            }
            GridRow {
                Text("URL").padding(.vertical, 5)
                url(.dev).padding(.vertical, 5).gridCellColumns(2)
                Color(nsColor: .separatorColor).frame(width: 1).gridCellUnsizedAxes(.vertical)
                url(.prod).padding(.vertical, 5).gridCellColumns(2)
            }
            ForEach(Row.allCases, id: \.self) { row in
                GridRow {
                    Text(row.rawValue).padding(.vertical, 5)
                    value(row, .dev).frame(width: 180, alignment: .leading).padding(.vertical, 5)
                    control(row, .dev).frame(width: 60, alignment: .leading).padding(.vertical, 5)
                    Color(nsColor: .separatorColor).frame(width: 1).gridCellUnsizedAxes(.vertical)
                    value(row, .prod).frame(width: 180, alignment: .leading).padding(.vertical, 5)
                    control(row, .prod).frame(width: 60, alignment: .leading).padding(.vertical, 5)
                }
            }
        }
        .buttonStyle(.bordered)
        .disabled(store.isBusy || store.host == nil)
        .confirmationDialog(
            confirmation?.action == .apply ? "選択したビルドをApplyしますか？" : "現在の稼働版を再起動しますか？",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.action.rawValue) {
                    Task { await store.run(confirmation.action, environment: confirmation.environment) }
                    self.confirmation = nil
                }
            }
            Button("キャンセル", role: .cancel) { confirmation = nil }
        } message: {
            if let confirmation {
                let environment = confirmation.environment
                let state = store.state(environment)
                let build = state.builds.first { $0.id == state.selectedBuild }
                Text("\(store.host?.name ?? "") / \(environment.rawValue)\n\(store.host?.url(for: environment) ?? "")\n\(confirmation.action == .apply ? build?.label ?? "" : state.running?.label ?? "")\nMock：サンプルデータだけが変化します。")
            }
        }
    }

    private func url(_ environment: ServerEnvironment) -> some View {
        let url = store.host?.url(for: environment) ?? "URL未設定"
        return Text(url)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 248, alignment: .leading)
            .help(url)
            .textSelection(.enabled)
    }

    @ViewBuilder private func value(_ row: Row, _ environment: ServerEnvironment) -> some View {
        let state = store.state(environment)
        switch row {
        case .status:
            Text(state.checkedAt == nil ? "未確認" : "最終確認：応答あり")
                .foregroundStyle(.secondary)
        case .running:
            Text(state.running?.label ?? "未取得")
                .font(.callout.monospaced())
                .lineLimit(1)
                .textSelection(.enabled)
        case .fetch:
            Group {
                if let date = state.fetchedAt {
                    Text(date, format: .dateTime.hour().minute().second())
                } else {
                    Text(environment == .dev ? "未取得" : "Build時にFetch")
                }
            }
            .foregroundStyle(.secondary)
        case .commit:
            if environment == .dev {
                Picker("Dev commit", selection: selection(\.selectedCommit, environment)) {
                    Text("選択").tag("")
                    ForEach(state.commits) { commit in Text(commit.label).tag(commit.id) }
                }
                .labelsHidden()
            } else {
                Text("最新main（自動）").foregroundStyle(.secondary)
            }
        case .build:
            Picker("\(environment.rawValue) ビルド", selection: selection(\.selectedBuild, environment)) {
                Text(state.builds.isEmpty ? "ビルドなし" : "選択").tag("")
                ForEach(state.builds) { build in Text(build.label).tag(build.id) }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder private func control(_ row: Row, _ environment: ServerEnvironment) -> some View {
        let state = store.state(environment)
        switch row {
        case .status:
            Button("再起動") { confirmation = (.restart, environment) }
                .disabled(state.checkedAt == nil)
        case .fetch where environment == .dev:
            actionButton(.fetch, environment)
        case .commit:
            actionButton(.build, environment)
                .disabled(environment == .dev && state.selectedCommit.isEmpty)
        case .build:
            Button("Apply") { confirmation = (.apply, environment) }
                .disabled(state.selectedBuild.isEmpty || state.checkedAt == nil)
        default:
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        }
    }

    private func actionButton(_ action: ServerAction, _ environment: ServerEnvironment) -> some View {
        Button(action.rawValue) {
            Task { await store.run(action, environment: environment) }
        }
    }

    private func selection(_ field: WritableKeyPath<ServerPanelState, String>, _ environment: ServerEnvironment) -> Binding<String> {
        Binding(
            get: { store.state(environment)[keyPath: field] },
            set: { store.select($0, field: field, environment: environment) }
        )
    }
}
