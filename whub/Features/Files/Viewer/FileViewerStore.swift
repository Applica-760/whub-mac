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
        }
    }
    private var fileChanges: AnyCancellable?

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
