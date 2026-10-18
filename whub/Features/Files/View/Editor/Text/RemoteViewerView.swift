import AppKit
import SwiftUI

struct RemoteViewerView: View {
    @ObservedObject var store: RemoteEditorStore
    let location: FileLocation
    let editorID: String

    var body: some View {
        VStack(spacing: 0) {
            switch store.states[location] {
            case .loading:
                ProgressView(store.file(for: location) == nil ? "本文を取得中…" : "本文を再取得中…（表示は前回取得分）")
                    .padding(8)
            case let .failed(message):
                Text("\(message)\n\(store.file(for: location) == nil ? "リロードで再取得できます。" : "本文・編集内容は保持されています。最新状態を確認できません。")")
                    .foregroundStyle(.orange).padding(8)
            case .disconnected:
                Text("切断しました。編集内容は保持されています。")
                    .foregroundStyle(.orange).padding(8)
            case .loaded, nil:
                EmptyView()
            }
            if let remote = store.fileStores[location] {
                if remote.isSaving { ProgressView("保存中…").padding(8) }
                if let message = remote.message { Text(message).foregroundStyle(.orange).padding(8) }
            }
            if let file = store.file(for: location), case let .text(source) = file.content {
                CodeEditorView(state: file, editorID: editorID, onEdit: {}, source: source,
                                language: codeLanguages[(location.name as NSString).pathExtension.lowercased()], hunks: [])
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
