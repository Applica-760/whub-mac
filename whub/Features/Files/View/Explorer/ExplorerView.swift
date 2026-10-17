import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct ExplorerSidebar: View {
    let onFileSelect: () -> Void
    let onOpenInBrowser: (URL) -> Void
    @EnvironmentObject private var files: FilesStore

    var body: some View {
        ExplorerView(onFileSelect: onFileSelect, onOpenInBrowser: onOpenInBrowser, store: files.explorer)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 640)
    }
}

struct ExplorerView: View {
    let onFileSelect: () -> Void
    let onOpenInBrowser: (URL) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var servers: RemoteServerStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var gitStore: GitStore
    @ObservedObject var store: ExplorerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExplorerPulldownView(store: store)
            if store.showsDiff, store.selectedLocation?.localURL != nil {
                ExplorerDiffView(git: gitStore, editor: files.activeEditor,
                                 onPreview: { openDiff($0, preview: true) },
                                 onOpen: { openDiff($0, preview: false) })
            } else {
                ExplorerTreeView(
                    store: store,
                    gitStore: gitStore,
                    onFilePreview: { location in
                        files.preview(location, hosts: hosts, connections: connections, servers: servers)
                        onFileSelect()
                    },
                    onFileOpen: { location in
                        files.open(location, hosts: hosts, connections: connections, servers: servers)
                        onFileSelect()
                    },
                    onShowDiff: { openDiff($0, preview: false) },
                    onAction: performAction,
                    onCommitName: files.commitName
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            ExplorerMenuView(canRefresh: store.canRefresh, canShowDiff: store.selectedLocation?.localURL != nil,
                             showsDiff: $store.showsDiff) {
                files.refresh()
            }
        }
        .onChange(of: store.showsDiff, initial: true) { gitStore.setDiffEnabled(store.showsDiff) }
        .onAppear { store.startWatching() }
        .onDisappear { store.stopWatching() }
        .task(id: store.updateID(projects: projects, hosts: hosts, connections: connections,
                                 refreshID: files.refreshID)) {
            await store.update(projects: projects, hosts: hosts, connections: connections, servers: servers,
                               refreshID: files.refreshID, context: context)
        }
    }

    private func performAction(_ action: ExplorerContextMenu.Action, location: FileLocation) {
        guard let url = location.localURL else { return }
        do {
            switch action {
            case .openInBrowser:
                onOpenInBrowser(url)
            case .trash:
                let alert = NSAlert()
                alert.messageText = "\(url.lastPathComponent)をゴミ箱に移動しますか？"
                alert.addButton(withTitle: "キャンセル")
                alert.addButton(withTitle: "ゴミ箱に移動")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                try files.trash(url)
            }
        } catch {
            EditorDialogs.show(error: error)
        }
    }

    private func openDiff(_ location: FileLocation, preview: Bool) {
        files.openDiff(location, preview: preview)
        onFileSelect()
    }
}
