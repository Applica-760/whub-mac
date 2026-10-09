import SwiftUI

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
                if let location = store.selectedLocation, let state = store.local.fileStores[location] {
                    FileContent(state: state, editorID: editorID, refreshID: files.refreshID) { [weak store] in
                        if store?.previewLocation == location { store?.open(location) }
                    }
                    .id(location)
                } else if let location = store.selectedLocation, case .remote = location {
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
