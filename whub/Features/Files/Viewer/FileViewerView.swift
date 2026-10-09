import AppKit
import SwiftUI
import WhubCore

struct FileViewerView: View {
    @EnvironmentObject private var gitStore: GitStore
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: FileViewerStore
    @SceneStorage("fileEditorID") private var editorID = UUID().uuidString

    var body: some View {
        VStack(spacing: 8) {
            TabBarContainer(
                ids: store.fileLocations,
                selection: store.selectedLocation,
                select: selectTab,
                close: { location in
                    tabFocus.activate()
                    store.close(location)
                },
                canClose: { _ in true },
                move: store.move,
                isShortcutTarget: tabFocus.contains
            ) { location, isSelected, actions in
                if let fileStore = store.fileStores[location], let fileURL = location.localURL {
                    let titleColor: Color? = switch gitStore.changes[fileURL.standardizedFileURL] {
                    case .added: Color(nsColor: .systemGreen)
                    case .modified, .deleted: Color(nsColor: .systemOrange)
                    case nil: nil
                    }
                    TabBar(
                        title: location.name,
                        icon: IconList.image(for: fileURL),
                        isSelected: isSelected,
                        isPreview: location == store.previewLocation,
                        titleColor: titleColor,
                        status: fileStore.diskMessage != nil ? (.orange, "外部変更・読み込みエラー")
                            : fileStore.hasUnsavedChanges ? (.primary, "未保存") : nil,
                        openAction: { store.open(location) },
                        action: actions.select,
                        closeAction: actions.close
                    )
                } else if case .remote = location {
                    TabBar(title: location.name, icon: Image(systemName: "network"),
                           isSelected: isSelected, isPreview: location == store.previewLocation,
                           openAction: { store.open(location) }, action: actions.select, closeAction: actions.close)
                        .help(location.path)
                }
            }

            if let message = store.watchError {
                Text(message).foregroundStyle(.orange)
            }

            WidgetFrame {
                if let location = store.selectedLocation, let state = store.fileStores[location] {
                    FileContent(state: state, editorID: editorID) { [weak store] in
                        if store?.previewLocation == location { store?.open(location) }
                    }
                    .id(location)
                } else if let location = store.selectedLocation, case .remote = location {
                    RemoteFileViewerView(store: store.remote, location: location, editorID: editorID)
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

    private func selectTab(_ location: FileLocation) {
        tabFocus.activate()
        store.select(location)
        DispatchQueue.main.async {
            guard store.selectedLocation == location,
                  let editor = (store.fileStores[location] ?? store.remote.file(for: location))?.editorViews[editorID]?.documentView,
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
        switch state.content {
        case let .text(source):
            if let fileURL = state.fileURL {
                CodeViewerView(fileURL: fileURL, source: source, refreshID: 0,
                               state: state, editorID: editorID, onEdit: onEdit)
            }
        case .binary:
            if let fileURL = state.fileURL { BinaryViewerView(fileURL: fileURL) }
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}
