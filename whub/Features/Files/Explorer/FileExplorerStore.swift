import Combine
import Foundation
import SwiftData
import WhubCore

final class FileExplorerStore: ObservableObject {
    @Published var selectedLocation: FileLocation? {
        didSet {
            guard selectedLocation != oldValue else { return }
            remoteTree.stop()
            watcher.stop()
            gitRequestID += 1
            gitDirectories = []
            viewerStore?.gitRootURL = nil
            viewerStore?.gitChanges = [:]
            rootURL = nil
            watchError = nil
            directoryErrorMessage = nil
        }
    }
    private var basePathURL: URL?
    var selectedRootURL: URL? { selectedLocation?.localURL }

    @Published private(set) var worktreeURLs: [URL] = []
    @Published private(set) var rootURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var gitErrorMessage: String?
    @Published private(set) var watchError: String?
    @Published private(set) var directoryErrorMessage: String?
    @Published private(set) var treeRevision = 0

    let remoteTree = RemoteFileTreeStore()
    var treeLocation: FileLocation? {
        if case .remote = selectedLocation { return remoteTree.source?.root }
        return rootURL.map(FileLocation.local)
    }
    var rootItems: [FileItem] {
        if case .remote = selectedLocation { return remoteTree.rootItems }
        return localRootItems
    }
    private var localRootItems: [FileItem] = []

    init() {
        remoteTree.onChange = { [weak self] in
            // Outline callbacks may run while SwiftUI is updating its representable.
            DispatchQueue.main.async { self?.treeRevision += 1 }
        }
    }
    private(set) var decorations: [URL: GitChange] = [:]
    private var itemsByURL: [URL: FileItem] = [:]
    private var treeRootLocation: FileLocation?
    private var loadedTreeRevision = -1
    private var isVisible = false
    private weak var viewerStore: FileViewerStore?
    private var gitDirectories: Set<URL> = []
    private var gitRefreshTask: Task<Void, Never>?
    private var gitRequestID = 0
    private lazy var watcher = FileChangeWatcher { [weak self] event in
        self?.handleChanges(event)
    }

    private func handleChanges(_ event: FileChangeWatcher.Event) {
        guard isVisible, let rootURL else { return }
        guard case let .changed(paths) = event else { refresh(); return }
        let roots = [rootURL.standardizedFileURL.path, rootURL.resolvingSymlinksInPath().path]
        let treeChanged = paths.contains { path in
            roots.contains { root in
                if path == root || root.hasPrefix(path + "/") { return true }
                guard path.hasPrefix(root + "/") else { return false }
                let relative = path.dropFirst(root.count + 1)
                return !relative.split(separator: "/").contains { $0 == ".git" || $0 == ".DS_Store" }
            }
        }
        if treeChanged { refreshTree() }
        if treeChanged || Git.needsStatusRefresh(
            changedPaths: paths, worktreeRoots: roots, managementDirectories: gitDirectories
        ) { refreshGit() }
    }

    var cachedItems: [FileItem] {
        if case .remote = selectedLocation { return remoteTree.cachedItems }
        return Array(itemsByURL.values)
    }

    func startWatching(viewerStore: FileViewerStore) {
        self.viewerStore = viewerStore
        isVisible = true
        viewerStore.gitRootURL = rootURL
        refresh()
    }

    func stopWatching() {
        remoteTree.stop()
        isVisible = false
        gitRequestID += 1
        watcher.stop()
        if viewerStore?.gitRootURL == rootURL { viewerStore?.gitRootURL = nil }
    }

    func refresh() {
        refreshTree()
        refreshGit()
    }

    private func refreshGit() {
        guard isVisible, rootURL != nil, viewerStore != nil else { return }
        gitRequestID += 1
        guard gitRefreshTask == nil else { return }
        gitRefreshTask = Task { [weak self] in await self?.loadGit() }
    }

    private func loadGit() async {
        defer { gitRefreshTask = nil }
        while isVisible, let url = rootURL, let viewerStore, viewerStore.gitRootURL == url {
            let requestID = gitRequestID
            func isCurrent() -> Bool {
                isVisible && rootURL == url && gitRequestID == requestID
                    && viewerStore.gitRootURL == url
            }
            do {
                let directories = try await Git.managementDirectories(at: url)
                guard isCurrent() else { continue }
                gitDirectories = directories
                updateWatching()
                let changes = try await Git.changes(at: url)
                guard isCurrent() else { continue }
                viewerStore.gitChanges = changes
                gitErrorMessage = nil
            } catch GitError.notRepository {
                guard isCurrent() else { continue }
                gitDirectories = []
                updateWatching()
                viewerStore.gitChanges = [:]
                gitErrorMessage = nil
            } catch {
                guard isCurrent() else { continue }
                viewerStore.gitChanges = [:]
                gitErrorMessage = error.localizedDescription
            }
            break
        }
    }

    func refreshTree() {
        guard isVisible, rootURL != nil else { return }
        updateWatching()
        treeRevision += 1
    }

    private func updateWatching() {
        guard isVisible, let rootURL else { return }
        do {
            try watcher.start(paths: Set(gitDirectories.map(\.path)).union([rootURL.path]))
            watchError = nil
        } catch {
            watchError = error.localizedDescription
        }
    }

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

    func loadWorktrees(projects: [Project]) {
        let localProjects = projects.filter { $0.host is LocalHost }
        worktreeURLs = Set(localProjects.map { $0.host.worktreesPath }).flatMap { path in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return urls.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                return localProjects.contains { project in
                    let prefix = project.name + "-"
                    guard url.lastPathComponent.hasPrefix(prefix),
                          let number = Int(url.lastPathComponent.dropFirst(prefix.count)),
                          number > 0 else { return false }
                    return url.path == project.worktreePath(issueNumber: number)
                }
            }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func load(projects: [Project], context: ModelContext, viewerStore: FileViewerStore) async {
        self.viewerStore = viewerStore
        if rootURL == nil { viewerStore.gitChanges = [:] }
        errorMessage = nil
        gitErrorMessage = nil
        guard let selectedRootURL else {
            return
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && isVisible && self.selectedRootURL == selectedRootURL
        }
        do {
            let path: String
            if let project = projects.first(where: { $0.host is LocalHost && $0.path == selectedRootURL.path }) {
                path = try await ProjectStore(context: context).resolvePath(for: project)
            } else {
                path = selectedRootURL.path
            }
            guard isCurrent() else { return }
            let url = URL(fileURLWithPath: path)
            rootURL = url
            viewerStore.gitRootURL = url
            refresh()
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
        let refreshed = loadedTreeRevision != treeRevision
        let nextDecorations = TreeDiff.changes(for: gitChanges, under: rootURL)
        guard rootChanged || refreshed || decorations != nextDecorations else { return false }
        if rootChanged { itemsByURL.removeAll() }
        treeRootLocation = treeLocation
        loadedTreeRevision = treeRevision
        decorations = nextDecorations
        if rootChanged || refreshed {
            reportDirectoryError(nil)
            for item in itemsByURL.values { item.children = nil }
            localRootItems = rootURL.map(directoryContents) ?? []
        }
        return true
    }

    func isUnavailable(_ item: FileItem) -> Bool {
        guard let basePathURL, selectedRootURL?.standardizedFileURL == basePathURL,
              item.isDirectory, let url = item.location.localURL?.standardizedFileURL else { return false }
        return url.deletingLastPathComponent().path == basePathURL.path
            && ["projects", "worktrees"].contains(url.lastPathComponent)
    }

    func children(for item: FileItem?) -> [FileItem] {
        if case .remote = selectedLocation { return remoteTree.children(for: item) }
        guard let item else { return rootItems }
        guard item.isDirectory, !isUnavailable(item), let url = item.location.localURL else { return [] }
        if let children = item.children { return children }
        let children = directoryContents(at: url)
        item.children = children
        return children
    }

    private func directoryContents(at url: URL) -> [FileItem] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            reportDirectoryError("ディレクトリを読み込めません：\(url.path) — \(error.localizedDescription)")
            return []
        }
        return urls
            .filter { ![".git", ".DS_Store"].contains($0.lastPathComponent) }
            .map { url in
                let key = url.standardizedFileURL
                let item = FileItem(url: url)
                if let existing = itemsByURL[key], existing.isDirectory == item.isDirectory {
                    return existing
                }
                itemsByURL[key] = item
                return item
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.location.name.localizedStandardCompare($1.location.name) == .orderedAscending
            }
    }

    private func reportDirectoryError(_ message: String?) {
        let root = rootURL
        let revision = treeRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, rootURL == root, treeRevision == revision else { return }
            if directoryErrorMessage != message { directoryErrorMessage = message }
        }
    }
}

final class FileItem: NSObject {
    let location: FileLocation
    let isDirectory: Bool
    var children: [FileItem]?

    init(url: URL) {
        location = .local(url)
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    init(location: FileLocation, isDirectory: Bool) {
        self.location = location
        self.isDirectory = isDirectory
    }
}
