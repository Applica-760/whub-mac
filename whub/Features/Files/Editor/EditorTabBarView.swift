import AppKit
import SwiftUI
import WhubCore

struct EditorTabBarView: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var gitStore: GitStore
    let tabFocus: TabPaneFocus
    let editorID: String

    var body: some View {
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
