import Combine
import SwiftUI
import WhubCore

struct EditorView: View {
    @State private var tabFocus = TabPaneFocus()
    @State private var wasActive = false
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var files: FilesStore
    @Environment(\.explorerFocusNavigation) private var explorerFocus
    @State private var editorID = UUID().uuidString

    var body: some View {
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
        } header: {
            EditorTabBarView(tabFocus: tabFocus, editorID: editorID)
            if let message = store.local.watchError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(isActive).eraseToAnyPublisher()) { active in
            guard active != wasActive else { return }
            wasActive = active
            if active { restoreEditorFocus() }
            else { currentEditor?.savePosition() }
        }
    }

    private var currentEditor: CodeTextView? {
        guard case let .file(location) = store.selectedTab else { return nil }
        return store.file(for: location)?.editorViews.views[editorID]?.documentView as? CodeTextView
    }

    private func restoreEditorFocus() {
        guard activity?.isActive.value ?? isActive, let editor = currentEditor,
              editor.fileStore?.editorPositions[editorID] != nil, let window = editor.window else { return }
        let tab = store.selectedTab
        guard explorerFocus?.containsExplorer(window) != true else { return }
        let responder = window.firstResponder
        DispatchQueue.main.async {
            guard activity?.isActive.value != false, store.selectedTab == tab,
                  window.isKeyWindow, window.attachedSheet == nil,
                  explorerFocus?.containsExplorer(window) != true,
                  window.firstResponder === responder || window.firstResponder === window || window.firstResponder == nil,
                  editor.window === window, !editor.isHiddenOrHasHiddenAncestor else { return }
            if window.makeFirstResponder(editor) { editor.restorePosition() }
        }
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

struct FilesCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard NSApp.keyWindow?.firstResponder is CodeTextView else { return }
                NSApp.sendAction(#selector(CodeTextView.saveDocument(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                guard NSApp.keyWindow?.firstResponder is CodeTextView else { return }
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
