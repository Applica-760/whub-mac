import AppKit
import SwiftUI
import WhubCore

struct FileViewerView: View {
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: FileViewerStore
    @SceneStorage("fileEditorID") private var editorID = UUID().uuidString

    var body: some View {
        VStack(spacing: 8) {
            if !store.fileURLs.isEmpty {
                TabBarContainer(
                    ids: store.fileURLs,
                    selection: store.selectedFileURL,
                    select: selectTab,
                    close: { fileURL in
                        tabFocus.activate()
                        store.close(fileURL)
                    },
                    canClose: { _ in true },
                    move: store.move,
                    isShortcutTarget: tabFocus.contains
                ) { fileURL, isSelected, actions in
                    if let fileStore = store.fileStores[fileURL] {
                        let titleColor: Color? = switch store.gitChanges[fileURL.standardizedFileURL] {
                        case .added: Color(nsColor: .systemGreen)
                        case .modified, .deleted: Color(nsColor: .systemOrange)
                        case nil: nil
                        }
                        TabBar(
                            title: fileURL.lastPathComponent,
                            icon: IconList.image(for: fileURL),
                            isSelected: isSelected,
                            isPreview: fileURL == store.previewFileURL,
                            titleColor: titleColor,
                            status: fileStore.hasUnsavedChanges ? (.primary, "未保存") : nil,
                            openAction: { store.open(fileURL) },
                            action: actions.select,
                            closeAction: actions.close
                        )
                    }
                }
            }

            WidgetFrame {
                if let fileURL = store.selectedFileURL, let state = store.fileStores[fileURL] {
                    FileContent(state: state, editorID: editorID) { [weak store] in
                        if store?.previewFileURL == fileURL { store?.open(fileURL) }
                    }
                    .id(fileURL)
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

    private func selectTab(_ fileURL: URL) {
        tabFocus.activate()
        store.select(fileURL)
        DispatchQueue.main.async {
            guard store.selectedFileURL == fileURL,
                  let editor = store.fileStores[fileURL]?.editorViews[editorID]?.documentView,
                  let window = editor.window, tabFocus.contains(window) else { return }
            window.makeFirstResponder(editor)
        }
    }
}

private struct FileContent: View {
    @ObservedObject var state: FileStore
    let editorID: String
    let onEdit: () -> Void

    var body: some View {
        switch state.content {
        case let .text(source):
            CodeViewerView(
                fileURL: state.fileURL, source: source, refreshID: 0,
                state: state, editorID: editorID, onEdit: onEdit
            )
        case .binary:
            BinaryViewerView(fileURL: state.fileURL)
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}
