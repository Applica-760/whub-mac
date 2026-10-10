import SwiftData
import SwiftUI
import WhubCore

struct ExplorerView: View {
    let onFileSelect: () -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var connections: RemoteConnectionStore
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
                        files.preview(location, hosts: hosts, connections: connections)
                        onFileSelect()
                    },
                    onFileOpen: { location in
                        files.open(location, hosts: hosts, connections: connections)
                        onFileSelect()
                    },
                    onShowDiff: { openDiff($0, preview: false) }
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
            await store.update(projects: projects, hosts: hosts, connections: connections,
                               refreshID: files.refreshID, context: context)
        }
    }

    private func openDiff(_ location: FileLocation, preview: Bool) {
        files.openDiff(location, preview: preview)
        onFileSelect()
    }
}
