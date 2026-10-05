import Combine
import Foundation
import SwiftData
import WhubCore

final class FileExplorerStore: ObservableObject {
    @Published var selectedRootURL: URL? {
        didSet {
            guard selectedRootURL != oldValue else { return }
            watcher.stop()
            rootURL = nil
            watchError = nil
            directoryErrorMessage = nil
        }
    }
    @Published private(set) var worktreeURLs: [URL] = []
    @Published private(set) var rootURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var gitErrorMessage: String?
    @Published private(set) var watchError: String?
    @Published private(set) var directoryErrorMessage: String?
    @Published private(set) var treeRevision = 0

    private(set) var rootItems: [FileItem] = []
    private(set) var decorations: [URL: GitChange] = [:]
    private var itemsByURL: [URL: FileItem] = [:]
    private var treeRootURL: URL?
    private var loadedTreeRevision = -1
    private var isVisible = false
    private lazy var watcher = FileChangeWatcher { [weak self] event in
        guard let self, isVisible, let rootURL else { return }
        if case let .changed(paths) = event {
            let roots = [rootURL.standardizedFileURL.path, rootURL.resolvingSymlinksInPath().path]
            guard paths.contains(where: { path in
                roots.contains { root in
                    if path == root || root.hasPrefix(path + "/") { return true }
                    guard path.hasPrefix(root + "/") else { return false }
                    let relative = path.dropFirst(root.count + 1)
                    return !relative.split(separator: "/").contains { $0 == ".git" || $0 == ".DS_Store" }
                }
            }) else { return }
        }
        refreshTree()
    }

    var cachedItems: [FileItem] { Array(itemsByURL.values) }

    func startWatching() {
        isVisible = true
        refreshTree()
    }

    func stopWatching() {
        isVisible = false
        watcher.stop()
    }

    func refreshTree() {
        guard isVisible, rootURL != nil else { return }
        updateWatching()
        treeRevision += 1
    }

    private func updateWatching() {
        guard isVisible, let rootURL else { return }
        do {
            try watcher.start(paths: [rootURL.path])
            watchError = nil
        } catch {
            watchError = error.localizedDescription
        }
    }

    func availableURLs(projects: [Project]) -> [URL] {
        projects.map { URL(fileURLWithPath: $0.path) } + worktreeURLs
    }

    func selectDefaultRoot(projects: [Project]) {
        selectedRootURL = projects.first { $0.name == "whub-mac" }
            .map { URL(fileURLWithPath: $0.path) } ?? availableURLs(projects: projects).first
    }

    func validateSelection(projects: [Project]) {
        if !availableURLs(projects: projects).contains(where: { $0 == selectedRootURL }) {
            selectDefaultRoot(projects: projects)
        }
    }

    func basePath(projects: [Project]) -> String? {
        projects.first { project in
            guard let selectedRootURL else { return false }
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
        if rootURL == nil { viewerStore.gitChanges = [:] }
        errorMessage = nil
        gitErrorMessage = nil
        guard let selectedRootURL else { return }
        func isCurrent() -> Bool {
            !Task.isCancelled && isVisible && self.selectedRootURL == selectedRootURL
        }
        do {
            let path: String
            if let project = projects.first(where: { $0.path == selectedRootURL.path }) {
                guard project.host is LocalHost else {
                    errorMessage = "Remote project files are not available yet."
                    return
                }
                path = try await ProjectStore(context: context).resolvePath(for: project)
            } else {
                path = selectedRootURL.path
            }
            guard isCurrent() else { return }
            let url = URL(fileURLWithPath: path)
            rootURL = url
            do {
                let changes = try await Git.changes(at: url)
                guard isCurrent() else { return }
                viewerStore.gitChanges = changes
            } catch GitError.notRepository {
                guard isCurrent() else { return }
                viewerStore.gitChanges = [:]
            } catch {
                guard isCurrent() else { return }
                viewerStore.gitChanges = [:]
                gitErrorMessage = error.localizedDescription
            }
            refreshTree()
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    func updateTree(gitChanges: [URL: GitChange]) -> Bool {
        let rootChanged = treeRootURL != rootURL
        let refreshed = loadedTreeRevision != treeRevision
        let nextDecorations = Self.decorations(for: gitChanges, under: rootURL)
        guard rootChanged || refreshed || decorations != nextDecorations else { return false }
        if rootChanged { itemsByURL.removeAll() }
        treeRootURL = rootURL
        loadedTreeRevision = treeRevision
        decorations = nextDecorations
        if rootChanged || refreshed {
            reportDirectoryError(nil)
            for item in itemsByURL.values { item.children = nil }
            rootItems = rootURL.map(directoryContents) ?? []
        }
        return true
    }

    func children(for item: FileItem?) -> [FileItem] {
        guard let item else { return rootItems }
        guard item.isDirectory else { return [] }
        if let children = item.children { return children }
        let children = directoryContents(at: item.url)
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
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
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

    private static func decorations(for gitChanges: [URL: GitChange], under rootURL: URL?) -> [URL: GitChange] {
        guard let rootURL else { return [:] }
        let root = rootURL.standardizedFileURL
        var result = gitChanges
        for (url, change) in gitChanges {
            var parent = url.deletingLastPathComponent()
            while parent == root || parent.path.hasPrefix(root.path + "/") {
                let current = result[parent]
                result[parent] = (current == nil || current == .added) && change == .added ? .added : .modified
                if parent == root { break }
                parent = parent.deletingLastPathComponent()
            }
        }
        return result
    }
}

final class FileItem: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?

    init(url: URL) {
        self.url = url
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
