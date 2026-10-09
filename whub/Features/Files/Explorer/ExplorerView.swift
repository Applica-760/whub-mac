import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct ExplorerView: View {
    let onFileSelect: () -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var fileViewerStore: FileViewerStore
    @EnvironmentObject private var gitStore: GitStore
    @StateObject private var store = ExplorerStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExplorerPulldownView(store: store)
            ExplorerTreeView(
                store: store,
                gitStore: gitStore,
                onFilePreview: { location in
                    store.preview(location, viewer: fileViewerStore, connections: connections)
                    onFileSelect()
                },
                onFileOpen: { location in
                    store.open(location, viewer: fileViewerStore, connections: connections)
                    onFileSelect()
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            ExplorerMenuView(canRefresh: store.canRefresh) {
                fileViewerStore.refresh()
            }
        }
        .onAppear { store.startWatching(gitStore: gitStore) }
        .onDisappear { store.stopWatching() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .task(id: store.updateID(projects: projects, hosts: hosts, connections: connections,
                                 refreshID: fileViewerStore.refreshID)) {
            await store.update(projects: projects, hosts: hosts, connections: connections,
                               refreshID: fileViewerStore.refreshID, context: context, gitStore: gitStore)
        }
    }
}
