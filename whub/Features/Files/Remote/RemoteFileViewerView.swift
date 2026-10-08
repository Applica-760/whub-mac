import SwiftUI

struct RemoteFileViewerView: View {
    @ObservedObject var store: RemoteFileViewerStore
    let location: FileLocation
    let editorID: String

    var body: some View {
        VStack(spacing: 0) {
            Text("読み取り専用 · \(location.path)")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            switch store.states[location] {
            case .loading:
                ProgressView("本文を取得中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .loaded(file):
                if case let .text(source) = file.content {
                    CodeTextContent(state: file, editorID: editorID, onEdit: {}, source: source,
                                    language: codeLanguages[(location.name as NSString).pathExtension.lowercased()], hunks: [])
                        .background(Color(white: 0.07).opacity(0.75))
                }
            case let .failed(message):
                Text(message).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case nil:
                EmptyView()
            }
        }
    }
}
