import SwiftUI
import WhubCore

struct EditorView: View {
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var files: FilesStore
    @SceneStorage("fileEditorID") private var editorID = UUID().uuidString

    var body: some View {
        VStack(spacing: 8) {
            EditorTabBarView(tabFocus: tabFocus, editorID: editorID)

            if let message = store.local.watchError {
                Text(message).foregroundStyle(.orange)
            }

            WidgetFrame {
                if case let .diff(url) = store.selectedTab, let state = store.local.diffStores[url] {
                    DiffContent(state: state).id(url)
                } else if case let .file(location) = store.selectedTab, let state = store.local.fileStores[location] {
                    FileContent(state: state, editorID: editorID, refreshID: files.refreshID) { [weak store] in
                        if store?.previewTab == .file(location) { store?.open(.file(location)) }
                    }
                    .id(location)
                } else if case let .file(location) = store.selectedTab, case .remote = location {
                    RemoteViewerView(store: store.remote, location: location, editorID: editorID)
                        .id(location)
                } else {
                    Text("Select a file")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
    }
}

private struct FileContent: View {
    @ObservedObject var state: LocalFileStore
    let editorID: String
    let refreshID: Int
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.diskMessage {
                Text(message)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
            fileContent
        }
    }

    @ViewBuilder private var fileContent: some View {
        switch state.document.content {
        case let .text(source):
            LocalCodeEditorView(fileURL: state.fileURL, source: source, refreshID: refreshID,
                               state: state, editorID: editorID, onEdit: onEdit)
        case .binary:
            BinaryView(fileURL: state.fileURL)
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}

private struct DiffContent: View {
    @ObservedObject var state: LocalDiffStore

    var body: some View {
        VStack(spacing: 8) {
            if let warning = state.watchError { Text(warning).foregroundStyle(.orange) }
            if let error = state.errorMessage {
                ContentUnavailableView("差分を取得できません", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let diff = state.diff {
                if state.isLoading { ProgressView().controlSize(.small) }
                switch diff.content {
                case let .text(before, after):
                    if diff.change == nil { Text("未コミットの差分はありません").foregroundStyle(.secondary) }
                    DiffView(before: before, after: after, fileURL: diff.fileURL)
                case let .unsupported(reason):
                    ContentUnavailableView("テキスト比較の対象外", systemImage: "doc.badge.ellipsis",
                                           description: Text(message(for: reason)))
                }
            } else {
                ProgressView("差分を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func message(for reason: WhubCore.FileDiff.UnsupportedReason) -> String {
        switch reason {
        case .binary: "バイナリまたはUTF-8以外のファイルです。"
        case .conflict: "競合中のファイルです。競合を解消してから再読み込みしてください。"
        case .submodule: "サブモジュールの比較には対応していません。"
        case .symbolicLink: "シンボリックリンクの比較には対応していません。"
        case .fileType: "通常ファイル以外の比較には対応していません。"
        }
    }
}
