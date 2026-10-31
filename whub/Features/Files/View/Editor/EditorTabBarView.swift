import AppKit
import SwiftUI
import WhubGit

struct EditorTabBarView: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var gitStore: GitStore
    @EnvironmentObject private var files: FilesStore
    let tabFocus: TabPaneFocus
    let editorID: String
    let onShowPreview: (FileLocation) -> Void

    var body: some View {
        TabBarContainer(
            ids: store.tabs,
            selection: store.selectedTab,
            select: selectTab,
            close: { location in
                tabFocus.activate()
                store.close(location)
            },
            canClose: { _ in true },
            move: store.move,
            isShortcutTarget: tabFocus.contains,
            contextMenu: { tab in
                switch tab {
                case let .file(location), let .diff(location):
                    ExplorerContextMenu(location: location, isDirectory: false, basePath: files.explorer.treeBasePath,
                                        tabMenu: true, previewVisible: store.selectedTab == .file(location) && store.markdownPreviews.contains(location),
                                        onAction: { action, location in
                                            if case .showPreview = action { onShowPreview(location) }
                                        }, onShowDiff: { files.openDiff($0) })
                }
            }
        ) { tab, isSelected, actions in
            switch tab {
            case let .diff(location):
                TabBar(title: location.name + " · Diff", icon: Image(systemName: "arrow.left.arrow.right"),
                       isSelected: isSelected, isPreview: tab == store.previewTab,
                       openAction: { store.open(tab) }, action: actions.select, closeAction: actions.close)
                    .help(location.path + " — HEAD ↔ 保存済み")
            case let .file(location):
                if let fileStore = store.local.fileStores[location], let fileURL = location.localURL {
                    let titleColor: Color? = switch gitStore.changes[fileURL.standardizedFileURL] {
                    case .added: Color(nsColor: .systemGreen)
                    case .modified, .deleted: Color(nsColor: .systemOrange)
                    case nil: nil
                    }
                    TabBar(
                        title: location.name,
                        icon: IconList.image(for: fileURL),
                        isSelected: isSelected,
                        isPreview: tab == store.previewTab,
                        titleColor: titleColor,
                        status: fileStore.diskMessage != nil ? (.orange, "外部変更・読み込みエラー")
                            : fileStore.document.hasUnsavedChanges ? (.primary, "未保存") : nil,
                        openAction: { store.open(tab) },
                        action: actions.select,
                        closeAction: actions.close
                    )
                } else if case .remote = location {
                    TabBar(title: location.name, icon: Image(systemName: "network"),
                           isSelected: isSelected, isPreview: tab == store.previewTab,
                           status: store.remote.fileStores[location]?.message != nil ? (.orange, "保存・外部変更の確認が必要")
                               : store.remote.fileStores[location]?.isSaving == true ? (.secondary, "保存中")
                               : store.remote.fileStores[location]?.hasUnsavedChanges == true ? (.primary, "未保存") : nil,
                           openAction: { store.open(tab) }, action: actions.select, closeAction: actions.close)
                        .help(location.path)
                }
            }
        }
    }

    private func selectTab(_ tab: EditorTab) {
        tabFocus.activate()
        store.select(tab)
        DispatchQueue.main.async {
            guard store.selectedTab == tab, case let .file(location) = tab,
                  let editor = store.file(for: location)?.editorViews.views[editorID]?.documentView,
                  let window = editor.window, tabFocus.contains(window) else { return }
            window.makeFirstResponder(editor)
        }
    }
}
