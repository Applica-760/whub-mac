import AppKit
import Combine
import Foundation
import WhubCore

final class FileViewerStore: ObservableObject {
    @Published private(set) var fileLocations: [FileLocation] = []
    @Published private(set) var selectedLocation: FileLocation?
    @Published private(set) var previewLocation: FileLocation?
    @Published private(set) var refreshID = 0
    @Published var gitChanges: [URL: GitChange] = [:]
    @Published var gitRootURL: URL?
    @Published private(set) var fileStores: [FileLocation: FileStore] = [:] {
        didSet {
            fileChanges = Publishers.MergeMany(fileStores.values.map(\.objectWillChange))
                .sink { [weak self] _ in self?.objectWillChange.send() }
            updateWatching()
        }
    }
    let remote = RemoteFileViewerStore()
    private var remoteChanges: AnyCancellable?

    init() {
        remoteChanges = remote.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    private var fileChanges: AnyCancellable?
    private var isClosing = false
    private lazy var watcher = FileChangeWatcher { [weak self] event in
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

    func managesGitStatus(for fileURL: URL) -> Bool {
        guard let gitRootURL else { return false }
        let roots = [gitRootURL.standardizedFileURL.path, gitRootURL.resolvingSymlinksInPath().path]
        let paths = [fileURL.standardizedFileURL.path, fileURL.resolvingSymlinksInPath().path]
        return paths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

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

    func refresh() {
        refreshID += 1
        remote.refresh()
    }

    func open(_ location: FileLocation) {
        guard location.localURL != nil || remote.states[location] != nil else { return }
        loadIfNeeded(location)
        if !fileLocations.contains(location) {
            fileLocations.append(location)
        }
        selectedLocation = location
        if previewLocation == location { previewLocation = nil }
    }

    func preview(_ location: FileLocation) {
        guard location.localURL != nil || remote.states[location] != nil else { return }
        if fileLocations.contains(location) && previewLocation != location {
            selectedLocation = location
            return
        }
        if let previewLocation, let index = fileLocations.firstIndex(of: previewLocation) {
            if previewLocation != location {
                fileStores.removeValue(forKey: previewLocation)
                remote.close(previewLocation)
            }
            fileLocations[index] = location
        } else if !fileLocations.contains(location) {
            fileLocations.append(location)
        }
        loadIfNeeded(location)
        previewLocation = location
        selectedLocation = location
    }

    func close(_ location: FileLocation) {
        guard !isClosing, fileLocations.contains(location) else { return }
        isClosing = true
        defer { isClosing = false }
        guard fileStores[location]?.confirmClose() != false else { return }
        guard let index = fileLocations.firstIndex(of: location) else { return }
        fileLocations.remove(at: index)
        fileStores.removeValue(forKey: location)
        remote.close(location)
        if previewLocation == location { previewLocation = nil }
        guard selectedLocation == location else { return }
        selectedLocation = index < fileLocations.count ? fileLocations[index] : fileLocations.last
    }

    private func loadIfNeeded(_ location: FileLocation) {
        guard fileStores[location] == nil, let url = location.localURL else { return }
        fileStores[location] = FileStore(fileURL: url)
    }

    func move(_ location: FileLocation, before target: FileLocation?) {
        guard let reordered = reorderedTabs(fileLocations, moving: location, before: target, identifiedBy: \.self)
        else { return }
        fileLocations = reordered
        if previewLocation == location { previewLocation = nil }
    }

    func select(_ location: FileLocation) {
        guard fileLocations.contains(location) else { return }
        selectedLocation = location
    }
}
