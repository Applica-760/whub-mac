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
                    ForEach(remoteSources, id: \.hostID) { source in
                        let entries = remoteStore.entries(for: [source])
                        if !entries.isEmpty {
                            Divider()
                            Section {
                                ForEach(entries) { entry in
                                    Text(entry.name).tag(Optional(entry.id))
                                }
                            } header: {
                                Text(source.hostName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
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

            ForEach(hosts) { host in
                if remoteSources.contains(where: { $0.hostID == host.persistentModelID }),
                   let state = remoteStore.states[host.persistentModelID] {
                    switch state {
                    case .loading:
                        Text("\(host.name)：一覧を取得中…")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    case let .failed(message):
                        Text("\(host.name)：\(message)")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    case .loaded: EmptyView()
                    }
                }
            }

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
                    ForEach(store.remoteTree.states.keys.sorted(), id: \.self) { path in
                        switch store.remoteTree.states[path] {
                        case .loading:
                            Text("\(path.isEmpty ? "ルート" : path)：取得中…")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        case let .failed(message):
                            Text("\(path.isEmpty ? "ルート" : path)：\(message) — リロードで再取得")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        default: EmptyView()
                        }
                    }
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
        hosts.compactMap { host in
            guard let session = connections.session(for: host) else { return nil }
            return .init(hostID: host.persistentModelID, hostName: host.name,
                         projectsPath: host.projectsPath, worktreesPath: host.worktreesPath,
                         sessionID: ObjectIdentifier(session))
        }
    }

    private var remoteEntries: [RemoteWorkspaceStore.Entry] { remoteStore.entries(for: remoteSources) }

    private var availableLocations: [FileLocation] {
        store.availableLocations(projects: projects, remote: remoteEntries.map(\.id))
    }

    private func updateRemoteTree() {
        guard let location = store.selectedLocation,
              case let .remote(hostID, root) = location,
              let host = hosts.first(where: { $0.persistentModelID == hostID }),
              let session = connections.session(for: host) else {
            store.remoteTree.update(source: nil, refreshID: fileViewerStore.refreshID, list: nil)
            return
        }
        store.remoteTree.update(
            source: .init(root: location, sessionID: ObjectIdentifier(session)),
            refreshID: fileViewerStore.refreshID
        ) { path in
            try await session.listDirectory(root: root, path: path)
        }
    }

    private func updateRemote() {
        let sessions = Dictionary(uniqueKeysWithValues: hosts.compactMap { host in
            connections.session(for: host).map { (host.persistentModelID, $0) }
        })
        remoteStore.update(sources: remoteSources, refreshID: fileViewerStore.refreshID) { source, root in
            guard let session = sessions[source.hostID], ObjectIdentifier(session) == source.sessionID else {
                throw RemoteSessionError.disconnected
            }
            return try await session.listDirectory(root: root)
        }
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
