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
    @Published private(set) var fileStates: [URL: FileState] = [:]

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
            if previewFileURL != fileURL { fileStates.removeValue(forKey: previewFileURL) }
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
        fileStates.removeValue(forKey: fileURL)
        if previewFileURL == fileURL { previewFileURL = nil }
        guard selectedFileURL == fileURL else { return }
        selectedFileURL = index < fileURLs.count ? fileURLs[index] : fileURLs.last
    }

    private func loadIfNeeded(_ fileURL: URL) {
        guard fileStates[fileURL] == nil else { return }
        fileStates[fileURL] = FileState(fileURL: fileURL)
    }

    func select(_ fileURL: URL) {
        guard fileURLs.contains(fileURL) else { return }
        selectedFileURL = fileURL
    }
}


final class FileState: ObservableObject {
    enum Content {
        case text(String)
        case binary
        case error(String)
    }

    let fileURL: URL
    @Published var content: Content
    let loadedSource: String?
    let textStorage: NSTextStorage
    let undoManager = UndoManager()
    // ponytail: retain editors until the file closes; evict closed scenes if window churn matters.
    var editorViews: [String: NSScrollView] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        let loadedContent: Content
        do {
            let data = try Data(contentsOf: fileURL)
            loadedContent = String(data: data, encoding: .utf8).map(Content.text) ?? .binary
        } catch {
            loadedContent = .error(error.localizedDescription)
        }
        content = loadedContent
        if case let .text(source) = loadedContent {
            loadedSource = source
            textStorage = NSTextStorage(string: source)
        } else {
            loadedSource = nil
            textStorage = NSTextStorage()
        }
    }
}
