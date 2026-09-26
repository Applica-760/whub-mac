import Combine
import Foundation

final class FileViewerStore: ObservableObject {
    @Published private(set) var fileURLs: [URL] = []
    @Published private(set) var selectedFileURL: URL?
    @Published private(set) var refreshID = 0

    func refresh() {
        refreshID += 1
    }

    func open(_ fileURL: URL) {
        if !fileURLs.contains(fileURL) {
            fileURLs.append(fileURL)
        }
        selectedFileURL = fileURL
    }

    func close(_ fileURL: URL) {
        guard let index = fileURLs.firstIndex(of: fileURL) else { return }
        fileURLs.remove(at: index)
        guard selectedFileURL == fileURL else { return }
        selectedFileURL = index < fileURLs.count ? fileURLs[index] : fileURLs.last
    }

    func select(_ fileURL: URL) {
        guard fileURLs.contains(fileURL) else { return }
        selectedFileURL = fileURL
    }
}
