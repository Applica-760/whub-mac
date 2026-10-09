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
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            ExplorerMenuView(canRefresh: store.canRefresh) {
                files.refresh()
            }
        }
        .onAppear { store.startWatching() }
        .onDisappear { store.stopWatching() }
        .task(id: store.updateID(projects: projects, hosts: hosts, connections: connections,
                                 refreshID: files.refreshID)) {
            await store.update(projects: projects, hosts: hosts, connections: connections,
                               refreshID: files.refreshID, context: context)
        }
    }
}
