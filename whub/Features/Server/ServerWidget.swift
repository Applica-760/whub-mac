import SwiftUI

struct ServerWidget: View {
    @State private var host = "Linux A"
    @State private var environment: ServerMockEnvironment = .dev
    @State private var servers: [String: ServerMockState] = [:]
    @State private var operation: ServerMockOperation?
    @State private var confirmation: ServerMockAction?

    private var key: String { "\(host)-\(environment.rawValue)" }
    private var server: ServerMockState { servers[key] ?? ServerMockState() }
    private var url: String {
        "http://\(host == "Linux A" ? "linux-a" : "linux-b").example.com:\(environment == .dev ? 8081 : 8082)"
    }

    var body: some View {
        WidgetFrame {
            VStack(alignment: .leading, spacing: 16) {
                target
                Divider()
                status
                Divider()
                buildControls
                applyControls
                result
            }
            .padding(16)
        } header: {
            HStack {
                Label("Server", systemImage: "server.rack")
                    .font(.headline)
                Text("Mock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("エラー表示") {
                    Button("認証エラー") {
                        showError("unauthorized：Manager APIの認証が必要です。")
                    }
                    Button("ビルド失敗") {
                        showError("build_failed：Swiftのビルドに失敗しました。ビルドログを確認してください。")
                    }
                    Button("接続失敗") {
                        showError("接続できません。稼働状態は不明です。停止している場合は手動で復旧し、リロードしてください。")
                    }
                }
                .fixedSize()
                .disabled(operation != nil)
                Button {
                    start(.reload)
                } label: {
                    Label("リロード", systemImage: "arrow.clockwise")
                }
                .disabled(operation != nil)
            }
        }
        .task(id: operation?.id) {
            guard let operation else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                complete(operation)
            } catch {
                self.operation = nil
            }
        }
        .confirmationDialog(
            confirmation == .apply ? "選択したビルドを適用しますか？" : "現在の稼働版を再起動しますか？",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = confirmation {
                Button(action == .apply ? "適用する" : "再起動する") {
                    start(action)
                    confirmation = nil
                }
            }
            Button("キャンセル", role: .cancel) { confirmation = nil }
        } message: {
            Text("\(host) / \(environment.rawValue)\n\(url)\n\(confirmation == .apply ? selectedBuildLabel : server.running)\nサンプルデータだけが変化します。")
        }
    }

    private var target: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Host", selection: $host) {
                    Text("Linux A").tag("Linux A")
                    Text("Linux B").tag("Linux B")
                }
                .frame(maxWidth: 250)
                Picker("環境", selection: $environment) {
                    ForEach(ServerMockEnvironment.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer(minLength: 0)
            }
            .disabled(operation != nil)
            Text(url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("配置・操作確認用のサンプルです。実サーバへの通信は行いません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(server.checkedAt == nil ? "未確認" : "最終確認時：応答あり",
                      systemImage: server.checkedAt == nil ? "questionmark.circle" : "checkmark.circle")
                Spacer()
                if let checkedAt = server.checkedAt {
                    Text(checkedAt, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                }
                Button("再起動") { confirmation = .restart }
                    .disabled(operation != nil || server.checkedAt == nil)
            }
            LabeledContent("稼働版", value: server.checkedAt == nil ? "未取得" : server.running)
                .font(.callout.monospaced())
            if server.checkedAt == nil {
                Text("リロードして状態を確認してください。停止中のサーバは手動復旧します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var buildControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ビルド").font(.subheadline.bold())
            if environment == .dev {
                HStack {
                    Button("Fetch") { start(.fetch) }
                    if let fetchedAt = server.fetchedAt {
                        Text("取得 \(fetchedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Fetch後にcommitを選択できます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Picker("commit", selection: selection(\.selectedCommit)) {
                        Text("選択してください").tag("")
                        if server.fetchedAt != nil {
                            ForEach(ServerMockCommit.samples) { commit in
                                Text(commit.label).tag(commit.id)
                            }
                        }
                    }
                    Button("ビルド") { start(.build) }
                        .disabled(server.selectedCommit.isEmpty)
                }
            } else {
                HStack {
                    Text("Fetchした最新mainのcommitを自動選択")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("最新mainをビルド") { start(.build) }
                }
            }
            Text("ビルドだけでは稼働版は変わりません。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(operation != nil)
    }

    private var applyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("適用").font(.subheadline.bold())
            HStack {
                Picker("ビルド", selection: selection(\.selectedBuild)) {
                    Text(server.builds.isEmpty ? "ビルドがありません" : "選択してください").tag("")
                    ForEach(server.builds) { build in
                        Text(build.label).tag(build.id)
                    }
                }
                Button("適用") { confirmation = .apply }
                    .disabled(server.selectedBuild.isEmpty || server.checkedAt == nil)
            }
            Text("選択した成果物を再ビルドせずに適用します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(operation != nil)
    }

    @ViewBuilder private var result: some View {
        if let operation {
            HStack {
                ProgressView().controlSize(.small)
                Text(operation.action.progress)
            }
            .font(.callout)
        } else if let error = server.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .textSelection(.enabled)
        } else if let message = server.message {
            Label(message, systemImage: "info.circle")
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var selectedBuildLabel: String {
        server.builds.first { $0.id == server.selectedBuild }?.label ?? "未選択"
    }

    private func selection(_ path: WritableKeyPath<ServerMockState, String>) -> Binding<String> {
        Binding(
            get: { server[keyPath: path] },
            set: { servers[key, default: ServerMockState()][keyPath: path] = $0 }
        )
    }

    private func start(_ action: ServerMockAction) {
        guard operation == nil else { return }
        operation = ServerMockOperation(key: key, environment: environment, action: action)
    }

    private func showError(_ message: String) {
        servers[key, default: ServerMockState()].error = message
    }

    private func complete(_ operation: ServerMockOperation) {
        var state = servers[operation.key] ?? ServerMockState()
        state.error = nil
        switch operation.action {
        case .reload:
            state.checkedAt = .now
            state.message = "状態を確認しました（Mock）"
        case .fetch:
            state.fetchedAt = .now
            state.selectedCommit = ServerMockCommit.samples[0].id
            state.message = "commit一覧を取得しました（Mock）"
        case .build:
            let commit = operation.environment == .prod ? ServerMockCommit.samples[0].id : state.selectedCommit
            guard !commit.isEmpty else { self.operation = nil; return }
            let build = ServerMockBuild(commit: commit, createdAt: .now)
            state.builds.insert(build, at: 0)
            state.selectedBuild = build.id
            if operation.environment == .prod { state.fetchedAt = .now }
            state.message = "ビルド成功：\(commit)。稼働版は変更していません（Mock）"
        case .apply:
            guard let build = state.builds.first(where: { $0.id == state.selectedBuild }) else {
                self.operation = nil
                return
            }
            state.running = "\(build.commit) / \(build.id.prefix(8))"
            state.checkedAt = .now
            state.message = "適用・再起動・起動確認が完了しました（Mock）"
        case .restart:
            state.checkedAt = .now
            state.message = "現在の稼働版を再起動し、応答を確認しました（Mock）"
        }
        servers[operation.key] = state
        self.operation = nil
    }
}

// shortcut: サンプル状態はメモリ内のみ。API接続時にServerの応答へ置き換える。
private struct ServerMockState {
    var checkedAt: Date?
    var fetchedAt: Date?
    var running = "f180ba9 / sample-01"
    var selectedCommit = ""
    var selectedBuild = ""
    var builds: [ServerMockBuild] = []
    var message: String?
    var error: String?
}

private enum ServerMockEnvironment: String, CaseIterable {
    case dev = "Dev", prod = "Prod"
}

private struct ServerMockCommit: Identifiable {
    let id: String
    let label: String

    static let samples = [
        Self(id: "3d05429", label: "3d05429 · main · Editorモデルを整理"),
        Self(id: "f180ba9", label: "f180ba9 · main · Server接続を改善"),
        Self(id: "a7c92e1", label: "a7c92e1 · feature/server · Server管理を試作"),
    ]
}

private struct ServerMockBuild: Identifiable {
    let id = UUID().uuidString
    let commit: String
    let createdAt: Date

    var label: String {
        "\(id.prefix(8)) · \(commit) · \(createdAt.formatted(date: .omitted, time: .standard))"
    }
}

private enum ServerMockAction {
    case reload, fetch, build, apply, restart

    var progress: String {
        switch self {
        case .reload: "状態を確認中…"
        case .fetch: "commit情報を取得中…"
        case .build: "ビルド中…"
        case .apply: "適用・起動確認中…"
        case .restart: "再起動・起動確認中…"
        }
    }
}

private struct ServerMockOperation: Identifiable {
    let id = UUID()
    let key: String
    let environment: ServerMockEnvironment
    let action: ServerMockAction
}
