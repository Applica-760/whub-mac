import AppKit
import Combine
import CoreServices
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
    private var eventStream: FSEventStreamRef?
    private var watchedPaths: Set<String> = []
    @Published private(set) var watchError: String?

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }

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
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        watchedPaths = paths
        watchError = nil
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let store = Unmanaged<FileViewerStore>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            let rescanFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            )
            let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
            MainActor.assumeIsolated {
                store.checkForExternalChanges(paths: rescan ? nil : paths)
                DispatchQueue.main.async { [weak store] in store?.updateWatching() }
            }
        }, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        else {
            watchError = "ファイル変更の監視を開始できません。"
            watchedPaths = []
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            watchError = "ファイル変更の監視を開始できません。"
            watchedPaths = []
            return
        }
        eventStream = stream
        checkForExternalChanges()
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
