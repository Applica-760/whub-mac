import Combine
import Foundation

@MainActor
final class LocalTreeStore: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var watchError: String?
    @Published private(set) var directoryErrorMessage: String?
    @Published private(set) var revision = 0
    private(set) var rootItems: [ExplorerItem] = []
    private var itemsByURL: [URL: ExplorerItem] = [:]
    private var loadedRoot: URL?
    private var loadedRevision = -1
    var managementDirectories: Set<URL> = [] {
        didSet { updateWatching() }
    }
    var onChanges: ((LocalFileWatcher.Event, Bool) -> Void)?
    private lazy var watcher = LocalFileWatcher { [weak self] event in self?.handleChanges(event) }
    var cachedItems: [ExplorerItem] { Array(itemsByURL.values) }

    func setRoot(_ url: URL?) {
        rootURL = url
        refresh()
    }

    func reset() {
        watcher.stop()
        rootURL = nil
        watchError = nil
        directoryErrorMessage = nil
    }

    func refresh() {
        guard rootURL != nil else { return }
        updateWatching()
        revision += 1
    }

    private func handleChanges(_ event: LocalFileWatcher.Event) {
        guard let rootURL else { return }
        var treeChanged = false
        defer { onChanges?(event, treeChanged) }
        guard case let .changed(paths) = event else { refresh(); return }
        let roots = [rootURL.standardizedFileURL.path, rootURL.resolvingSymlinksInPath().path]
        treeChanged = paths.contains(where: { path in
            roots.contains { root in
                if path == root || root.hasPrefix(path + "/") { return true }
                guard path.hasPrefix(root + "/") else { return false }
                let relative = path.dropFirst(root.count + 1)
                return !relative.split(separator: "/").contains { $0 == ".git" || $0 == ".DS_Store" }
            }
        })
        if treeChanged { refresh() }
    }

    private func updateWatching() {
        guard let rootURL else { return }
        do {
            try watcher.start(paths: Set(managementDirectories.map(\.path)).union([rootURL.path]))
            watchError = nil
        } catch {
            watchError = error.localizedDescription
        }
    }

    func updateTree() -> Bool {
        let changed = loadedRoot != rootURL
        guard changed || loadedRevision != revision else { return false }
        if changed { itemsByURL.removeAll() }
        loadedRoot = rootURL
        loadedRevision = revision
        reportDirectoryError(nil)
        for item in itemsByURL.values { item.children = nil }
        rootItems = rootURL.map(directoryContents) ?? []
        return true
    }

    func children(for item: ExplorerItem?) -> [ExplorerItem] {
        guard let item else { return rootItems }
        guard item.isDirectory, let url = item.location.localURL else { return [] }
        if let children = item.children { return children }
        let children = directoryContents(at: url)
        item.children = children
        return children
    }

    private func directoryContents(at url: URL) -> [ExplorerItem] {
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
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let item = ExplorerItem(location: .local(url), isDirectory: isDirectory)
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
        let revision = self.revision
        DispatchQueue.main.async { [weak self] in
            guard let self, rootURL == root, self.revision == revision else { return }
            if directoryErrorMessage != message { directoryErrorMessage = message }
        }
    }
}
