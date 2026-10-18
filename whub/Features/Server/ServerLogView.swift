import SwiftUI

struct ServerLogView: View {
    @ObservedObject var store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ログ").font(.subheadline.bold())
                Spacer()
                Menu("Mockエラー") {
                    Button("認証エラー") { sampleError("unauthorized：Manager APIの認証が必要です。") }
                    Button("ビルド失敗") { sampleError("build_failed：ビルドに失敗しました。ログを確認してください。") }
                    Button("接続失敗") { sampleError("接続できません。状態不明。停止時は手動復旧してください。") }
                }
                .fixedSize()
                .disabled(store.isBusy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if store.visibleLogs.isEmpty {
                        Text("操作結果・エラーをここに表示します。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.visibleLogs.reversed()) { entry in
                        HStack(alignment: .top, spacing: 4) {
                            if entry.isError { Image(systemName: "exclamationmark.triangle") }
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) \(entry.environment?.rawValue ?? "Mock") · \(entry.message)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 142)
            HStack(spacing: 5) {
                if let activity = store.activity {
                    ProgressView().controlSize(.mini)
                    Text(activity)
                } else {
                    Text("Mock · 実通信なし")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func sampleError(_ message: String) {
        store.append(message, hostID: store.hostID, isError: true)
    }
}
