import SwiftUI

struct RemoteFileViewerView: View {
    @ObservedObject var store: RemoteFileViewerStore
    let location: FileLocation
    let editorID: String

    var body: some View {
        if case .disconnected = store.states[location] {
            Text("切断しました")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text("読み取り専用 · \(location.path)")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            switch store.states[location] {
            case .loading:
                ProgressView(store.file(for: location) == nil ? "本文を取得中…" : "本文を再取得中…（表示は前回取得分）")
                    .padding(8)
            case let .failed(message):
                Text("\(message)\n\(store.file(for: location) == nil ? "リロードで再取得できます。" : "表示は前回取得分です。最新状態を確認できません。")")
                    .foregroundStyle(.orange).padding(8)
            case .loaded, .disconnected, nil:
                EmptyView()
            }
            if let file = store.file(for: location), case let .text(source) = file.content {
                CodeTextContent(state: file, editorID: editorID, onEdit: {}, source: source,
                                language: codeLanguages[(location.name as NSString).pathExtension.lowercased()], hunks: [])
                    .background(Color(white: 0.07).opacity(0.75))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
