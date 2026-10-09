import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class ExplorerStore: ObservableObject {
    @Published var selectedLocation: FileLocation? {
        didSet {
            guard selectedLocation != oldValue else { return }
            remoteTree.stop()
            localTree.reset()
            errorMessage = nil
        }
    }
    let localWorkspace = LocalWorkspaceStore()
    let localTree = LocalTreeStore()
    var projects: [Project] { localWorkspace.projects }
    var localBasePath: String? { localWorkspace.basePath }
    @Published private(set) var remoteSources: [RemoteWorkspaceStore.Source] = []
    let remoteWorkspace = RemoteWorkspaceStore()
    private var hosts: [RemoteHost] = []
    private var workspaceChanges: AnyCancellable?
    private var localChanges: AnyCancellable?

    var locations: [FileLocation] {
        availableLocations(projects: projects, remote: remoteWorkspace.entries(for: remoteSources), basePath: localBasePath)
    }
    var canRefresh: Bool { selectedLocation != nil || !remoteSources.isEmpty }
    var treeBasePath: String? { basePath(projects: projects) }

    struct UpdateID: Equatable {
        let projectNames: [String]
        let worktrees: LocalWorkspaceStore.LoadID
        let localBasePath: String?
        let sources: [RemoteWorkspaceStore.Source]
        let hostNames: [String]
        let selection: FileLocation?
    }

    func updateID(projects: [Project], hosts: [WhubCore.Host], connections: RemoteConnectionStore,
                  refreshID: Int) -> UpdateID {
        let local = projects.filter { $0.host is LocalHost }
        let sources = RemoteWorkspaceStore.connectedSources(
            hosts: hosts.compactMap { $0 as? RemoteHost }, connections: connections
        )
        return UpdateID(
            projectNames: local.map(\.name),
            worktrees: LocalWorkspaceStore.LoadID(projectPaths: local.map(\.path),
                                      worktreePaths: local.map { $0.host.worktreesPath }, refreshID: refreshID),
            localBasePath: hosts.first { $0 is LocalHost }?.basePath,
            sources: sources, hostNames: sources.map(\.hostName), selection: selectedLocation
        )
    }

    func update(projects: [Project], hosts: [WhubCore.Host], connections: RemoteConnectionStore,
                refreshID: Int, context: ModelContext) async {
        let id = updateID(projects: projects, hosts: hosts, connections: connections, refreshID: refreshID)
        self.hosts = hosts.compactMap { $0 as? RemoteHost }
        localWorkspace.update(projects: projects, basePath: id.localBasePath, id: id.worktrees)
        remoteSources = id.sources
        remoteWorkspace.update(hosts: self.hosts, connections: connections, refreshID: refreshID)
        validateCurrentSelection()
        remoteTree.update(location: selectedLocation, hosts: self.hosts,
                          connections: connections, refreshID: refreshID)
        await load(context: context)
    }

    private func validateCurrentSelection() {
        validateSelection(projects: projects, remote: remoteWorkspace.entries(for: remoteSources), basePath: localBasePath)
    }

    private var basePathURL: URL?
    var selectedRootURL: URL? { selectedLocation?.localURL }

    var worktreeURLs: [URL] { localWorkspace.worktreeURLs }
    var rootURL: URL? { localTree.rootURL }
    @Published private(set) var errorMessage: String?
    var watchError: String? { localTree.watchError }
    var directoryErrorMessage: String? { localTree.directoryErrorMessage }
    @Published private(set) var treeRevision = 0

    let remoteTree = RemoteTreeStore()
    var treeLocation: FileLocation? {
        if case .remote = selectedLocation { return remoteTree.source?.root }
        return rootURL.map(FileLocation.local)
    }
    var rootItems: [ExplorerItem] {
        if case .remote = selectedLocation { return remoteTree.rootItems }
        return localTree.rootItems
    }

    init() {
        localChanges = localTree.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.treeRevision += 1 }
        }
        workspaceChanges = remoteWorkspace.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                self.validateCurrentSelection()
                self.objectWillChange.send()
            }
        }
        remoteTree.onChange = { [weak self] in
            // Outline callbacks may run while SwiftUI is updating its representable.
            DispatchQueue.main.async { self?.treeRevision += 1 }
        }
    }
    private(set) var decorations: [URL: GitChange] = [:]
    private var treeRootLocation: FileLocation?
    private var loadedTreeRevision = -1
    private var isVisible = false
    var cachedItems: [ExplorerItem] {
        if case .remote = selectedLocation { return remoteTree.cachedItems }
        return localTree.cachedItems
    }

    func startWatching() {
        isVisible = true
        localTree.refresh()
    }

    func stopWatching() {
        isVisible = false
        remoteWorkspace.stop()
        remoteTree.stop()
        localWorkspace.stop()
    }

    func refresh() { localTree.refresh() }

    func availableLocations(projects: [Project], remote: [FileLocation], basePath: String?) -> [FileLocation] {
        let base = basePath.map { [FileLocation.local(URL(fileURLWithPath: $0))] } ?? []
        return base + projects.filter { $0.host is LocalHost }.map { .local(URL(fileURLWithPath: $0.path)) }
            + worktreeURLs.map(FileLocation.local) + remote
    }

    func validateSelection(projects: [Project], remote: [FileLocation], basePath: String?) {
        basePathURL = basePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let available = availableLocations(projects: projects, remote: remote, basePath: basePath)
        if !available.contains(where: { $0 == selectedLocation }) {
            selectedLocation = projects.first { $0.host is LocalHost && $0.name == "whub-mac" }
                .map { .local(URL(fileURLWithPath: $0.path)) } ?? available.first
        }
    }

    func basePath(projects: [Project]) -> String? {
        if selectedRootURL?.standardizedFileURL == basePathURL, let basePathURL { return basePathURL.path }
        return projects.first { project in
            guard project.host is LocalHost, let selectedRootURL else { return false }
            return selectedRootURL.path == project.path
                || selectedRootURL.path.hasPrefix(project.host.worktreesPath + "/")
        }?.host.basePath
    }

    private func load(context: ModelContext) async {
        errorMessage = nil
        guard let selectedRootURL else { return }
        func isCurrent() -> Bool {
            !Task.isCancelled && isVisible && self.selectedRootURL == selectedRootURL
        }
        do {
            let url = try await localWorkspace.resolve(selectedRootURL, context: context)
            guard isCurrent() else { return }
            localTree.setRoot(url)
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    func updateTree(gitChanges: [URL: GitChange]) -> Bool {
        let rootChanged = treeRootLocation != treeLocation
        if case .remote = selectedLocation {
            guard rootChanged || loadedTreeRevision != treeRevision else { return false }
            treeRootLocation = treeLocation
            loadedTreeRevision = treeRevision
            decorations = [:]
            return true
        }
        let refreshed = localTree.updateTree()
        let nextDecorations = TreeDiff.changes(for: gitChanges, under: rootURL)
        guard rootChanged || refreshed || decorations != nextDecorations else { return false }
        treeRootLocation = treeLocation
        loadedTreeRevision = treeRevision
        decorations = nextDecorations
        return true
    }

    func isUnavailable(_ item: ExplorerItem) -> Bool {
        guard let basePathURL, selectedRootURL?.standardizedFileURL == basePathURL,
              item.isDirectory, let url = item.location.localURL?.standardizedFileURL else { return false }
        return url.deletingLastPathComponent().path == basePathURL.path
            && ["projects", "worktrees"].contains(url.lastPathComponent)
    }

    func children(for item: ExplorerItem?) -> [ExplorerItem] {
        if case .remote = selectedLocation { return remoteTree.children(for: item) }
        if let item, isUnavailable(item) { return [] }
        return localTree.children(for: item)
    }
}
