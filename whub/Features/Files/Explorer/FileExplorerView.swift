import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: () -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \RemoteHost.name) private var hosts: [RemoteHost]
    @EnvironmentObject private var connections: RemoteConnectionStore
    @StateObject private var remoteStore = RemoteWorkspaceStore()
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var fileViewerStore: FileViewerStore
    @StateObject private var store = FileExplorerStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Project or Worktree", selection: $store.selectedLocation) {
                    if availableLocations.isEmpty {
                        Text("---").tag(FileLocation?.none)
                    }
                    ForEach(projects.filter { $0.host is LocalHost }) { project in
                        Text(project.name).tag(Optional(FileLocation.local(URL(fileURLWithPath: project.path))))
                    }
                    ForEach(store.worktreeURLs, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(FileLocation.local(url)))
                    }
                    RemoteWorkspaceMenuItems(store: remoteStore, sources: remoteSources)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                // Reserve the trigger position; expanded actions overlay the explorer.
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.horizontal)

            RemoteWorkspaceStatusView(store: remoteStore, sources: remoteSources)

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else {
                if let gitErrorMessage = store.gitErrorMessage {
                    Text(gitErrorMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if let watchError = store.watchError {
                    Text(watchError)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                if let directoryErrorMessage = store.directoryErrorMessage {
                    Text(directoryErrorMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if case .remote = store.selectedLocation {
                    RemoteFileTreeStatusView(states: store.remoteTree.states)
                }
                FileTreeView(
                    store: store,
                    basePath: store.basePath(projects: projects),
                    gitChanges: fileViewerStore.gitChanges,
                    onFilePreview: { fileURL in
                        fileViewerStore.preview(fileURL)
                        onFileSelect()
                    },
                    onFileOpen: { fileURL in
                        fileViewerStore.open(fileURL)
                        onFileSelect()
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            GeometryReader { geometry in
                ExplorerActionsView(
                    availableWidth: min(280, max(36, geometry.size.width - 32)),
                    canRefresh: store.selectedLocation != nil || !remoteSources.isEmpty
                ) {
                    fileViewerStore.refresh()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
            }
        }
        .focusedSceneValue(
            \.projectNavigation,
            ProjectNavigation(locations: availableLocations, selection: $store.selectedLocation)
        )
        .onAppear {
            updateRemote()
            updateRemoteTree()
            store.validateSelection(projects: projects, remote: remoteEntries.map(\.id))
            store.startWatching(viewerStore: fileViewerStore)
        }
        .onDisappear {
            store.stopWatching()
            remoteStore.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onChange(of: availableLocations) { _, _ in
            store.validateSelection(projects: projects, remote: remoteEntries.map(\.id))
        }
        .onChange(of: RemoteLoadID(sources: remoteSources, refreshID: fileViewerStore.refreshID), initial: true) { _, _ in
            updateRemote()
        }
        .onChange(of: RemoteTreeLoadID(
            location: store.selectedLocation,
            sources: remoteSources,
            refreshID: fileViewerStore.refreshID
        ), initial: true) { _, _ in
            updateRemoteTree()
        }
        .task(id: WorktreeLoadID(
            projectPaths: projects.compactMap { $0.host is LocalHost ? $0.path : nil },
            refreshID: fileViewerStore.refreshID
        )) {
            store.loadWorktrees(projects: projects)
        }
        .task(id: ExplorerLoadID(
            location: store.selectedLocation,
            refreshID: fileViewerStore.refreshID
        )) {
            await store.load(projects: projects, context: context, viewerStore: fileViewerStore)
        }
    }

    private var remoteSources: [RemoteWorkspaceStore.Source] {
        RemoteWorkspaceStore.connectedSources(hosts: hosts, connections: connections)
    }

    private var remoteEntries: [RemoteWorkspaceStore.Entry] { remoteStore.entries(for: remoteSources) }

    private var availableLocations: [FileLocation] {
        store.availableLocations(projects: projects, remote: remoteEntries.map(\.id))
    }

    private func updateRemoteTree() {
        store.remoteTree.update(location: store.selectedLocation, hosts: hosts,
                                connections: connections, refreshID: fileViewerStore.refreshID)
    }

    private func updateRemote() {
        remoteStore.update(hosts: hosts, connections: connections, refreshID: fileViewerStore.refreshID)
    }

}

private struct ExplorerLoadID: Equatable {
    let location: FileLocation?
    let refreshID: Int
}

private struct WorktreeLoadID: Equatable {
    let projectPaths: [String]
    let refreshID: Int
}

private struct RemoteLoadID: Equatable {
    let sources: [RemoteWorkspaceStore.Source]
    let refreshID: Int
}

private struct RemoteTreeLoadID: Equatable {
    let location: FileLocation?
    let sources: [RemoteWorkspaceStore.Source]
    let refreshID: Int
}
