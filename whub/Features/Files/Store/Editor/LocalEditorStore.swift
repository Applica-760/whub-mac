import Combine
import Foundation

final class LocalEditorStore: ObservableObject {
    @Published private(set) var diffStores: [URL: LocalDiffStore] = [:]

    func loadDiff(at url: URL) {
        if let store = diffStores[url] { store.refresh() }
        else {
            var directory = url.deletingLastPathComponent()
            while directory.path != "/", (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                directory.deleteLastPathComponent()
            }
            diffStores[url] = LocalDiffStore(fileURL: url, directory: directory)
        }
    }

    func closeDiff(at url: URL) {
        diffStores.removeValue(forKey: url)?.stop()
    }

    func refreshDiffs() {
        for store in diffStores.values { store.refresh() }
    }

    @Published private(set) var fileStores: [FileLocation: LocalFileStore] = [:] {
        didSet {
            fileChanges = Publishers.MergeMany(fileStores.values.map(\.objectWillChange))
                .sink { [weak self] _ in self?.objectWillChange.send() }
            updateWatching()
        }
    }
    private var fileChanges: AnyCancellable?
    private lazy var watcher = FileWatcher { [weak self] event in
        guard let self else { return }
        switch event {
        case let .changed(paths):
            checkForExternalChanges(paths: paths)
        case .rescan:
            checkForExternalChanges()
        }
        DispatchQueue.main.async { [weak self] in self?.updateWatching() }
    }
    @Published private(set) var watchError: String?

    func checkForExternalChanges(paths: [String]? = nil) {
        for (location, file) in fileStores {
            guard let url = location.localURL else { continue }
            let targets = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
            if let paths, !paths.contains(where: { path in
                targets.contains { $0 == path || $0.hasPrefix(path + "/") }
            }) { continue }
            file.checkForExternalChanges()
        }
    }

    private func updateWatching() {
        let paths = Set(fileStores.keys.compactMap(\.localURL).flatMap { url in
            [url.standardizedFileURL, url.resolvingSymlinksInPath()]
                .map { $0.deletingLastPathComponent().path }
        })
        watchError = nil
        do {
            let changed = try watcher.start(paths: paths)
            if changed && !paths.isEmpty { checkForExternalChanges() }
        } catch {
            watchError = error.localizedDescription
        }
    }

    func load(_ location: FileLocation) {
        guard fileStores[location] == nil, let url = location.localURL else { return }
        fileStores[location] = LocalFileStore(fileURL: url)
    }

    func close(_ location: FileLocation) {
        fileStores.removeValue(forKey: location)
    }
}
