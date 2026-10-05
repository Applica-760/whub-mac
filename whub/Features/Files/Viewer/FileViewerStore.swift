import AppKit
import Combine
import Foundation
import WhubCore

final class FileViewerStore: ObservableObject {
    @Published private(set) var fileURLs: [URL] = []
    @Published private(set) var selectedFileURL: URL?
    @Published private(set) var previewFileURL: URL?
    @Published private(set) var refreshID = 0
    @Published var gitChanges: [URL: GitChange] = [:]
    @Published private(set) var fileStores: [URL: FileStore] = [:] {
        didSet {
            fileChanges = Publishers.MergeMany(fileStores.values.map(\.objectWillChange))
                .sink { [weak self] _ in self?.objectWillChange.send() }
            updateWatching()
        }
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
    private var watchedPaths: Set<String> = []
    @Published private(set) var watchError: String?

    func checkForExternalChanges(paths: [String]? = nil) {
        for (url, file) in fileStores {
            let targets = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
            if let paths, !paths.contains(where: { path in
                targets.contains { $0 == path || $0.hasPrefix(path + "/") }
            }) { continue }
            file.checkForExternalChanges()
        }
    }

    private func updateWatching() {
        let paths = Set(fileStores.keys.flatMap { url in
            [url.standardizedFileURL, url.resolvingSymlinksInPath()]
                .map {
                    var directory = $0.deletingLastPathComponent()
                    while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
                        directory.deleteLastPathComponent()
                    }
                    return directory.path
                }
        })
        guard paths != watchedPaths else { return }
        watchError = nil
        do {
            try watcher.start(paths: paths)
            watchedPaths = paths
            if !paths.isEmpty { checkForExternalChanges() }
        } catch {
            watchError = error.localizedDescription
            watchedPaths = []
        }
    }

    func refresh() {
        refreshID += 1
    }

    func open(_ fileURL: URL) {
        loadIfNeeded(fileURL)
        if !fileURLs.contains(fileURL) {
            fileURLs.append(fileURL)
        }
        selectedFileURL = fileURL
        if previewFileURL == fileURL { previewFileURL = nil }
    }

    func preview(_ fileURL: URL) {
        if fileURLs.contains(fileURL) && previewFileURL != fileURL {
            selectedFileURL = fileURL
            return
        }
        if let previewFileURL, let index = fileURLs.firstIndex(of: previewFileURL) {
            if previewFileURL != fileURL { fileStores.removeValue(forKey: previewFileURL) }
            fileURLs[index] = fileURL
        } else if !fileURLs.contains(fileURL) {
            fileURLs.append(fileURL)
        }
        loadIfNeeded(fileURL)
        previewFileURL = fileURL
        selectedFileURL = fileURL
    }

    func close(_ fileURL: URL) {
        guard !isClosing, let file = fileStores[fileURL] else { return }
        isClosing = true
        defer { isClosing = false }
        guard file.confirmClose() else { return }
        guard let index = fileURLs.firstIndex(of: fileURL) else { return }
        fileURLs.remove(at: index)
        fileStores.removeValue(forKey: fileURL)
        if previewFileURL == fileURL { previewFileURL = nil }
        guard selectedFileURL == fileURL else { return }
        selectedFileURL = index < fileURLs.count ? fileURLs[index] : fileURLs.last
    }

    private func loadIfNeeded(_ fileURL: URL) {
        guard fileStores[fileURL] == nil else { return }
        fileStores[fileURL] = FileStore(fileURL: fileURL)
    }

    func move(_ fileURL: URL, before target: URL?) {
        guard let reordered = reorderedTabs(fileURLs, moving: fileURL, before: target, identifiedBy: \.self)
        else { return }
        fileURLs = reordered
        if previewFileURL == fileURL { previewFileURL = nil }
    }

    func select(_ fileURL: URL) {
        guard fileURLs.contains(fileURL) else { return }
        selectedFileURL = fileURL
    }
}
