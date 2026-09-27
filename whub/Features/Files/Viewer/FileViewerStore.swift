import Combine
import Foundation
import WhubCore

final class FileViewerStore: ObservableObject {
    @Published private(set) var fileURLs: [URL] = []
    @Published private(set) var selectedFileURL: URL?
    @Published private(set) var previewFileURL: URL?
    @Published private(set) var refreshID = 0
    @Published var gitChanges: [URL: GitChange] = [:]

    func refresh() {
        refreshID += 1
    }

    func open(_ fileURL: URL) {
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
            fileURLs[index] = fileURL
        } else if !fileURLs.contains(fileURL) {
            fileURLs.append(fileURL)
        }
        previewFileURL = fileURL
        selectedFileURL = fileURL
    }

    func close(_ fileURL: URL) {
        guard let index = fileURLs.firstIndex(of: fileURL) else { return }
        fileURLs.remove(at: index)
        if previewFileURL == fileURL { previewFileURL = nil }
        guard selectedFileURL == fileURL else { return }
        selectedFileURL = index < fileURLs.count ? fileURLs[index] : fileURLs.last
    }

    func select(_ fileURL: URL) {
        guard fileURLs.contains(fileURL) else { return }
        selectedFileURL = fileURL
    }
}
