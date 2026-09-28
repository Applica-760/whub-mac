import AppKit
import Combine
import Foundation

final class FileStore: ObservableObject {
    enum Content {
        case text(String)
        case binary
        case error(String)
    }

    let fileURL: URL
    @Published var content: Content
    @Published private(set) var savedSource: String?
    @Published private(set) var diskRevision = 0
    private var savedData: Data?
    let textStorage: NSTextStorage
    let undoManager = UndoManager()
    // ponytail: retain editors until the file closes; evict closed scenes if window churn matters.
    var editorViews: [String: NSScrollView] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
        let loadedContent: Content
        do {
            let data = try Data(contentsOf: fileURL)
            savedData = data
            loadedContent = String(data: data, encoding: .utf8).map(Content.text) ?? .binary
        } catch {
            loadedContent = .error(error.localizedDescription)
        }
        content = loadedContent
        if case let .text(source) = loadedContent {
            savedSource = source
            textStorage = NSTextStorage(string: source)
        } else {
            savedSource = nil
            textStorage = NSTextStorage()
        }
    }

    enum SaveError: LocalizedError {
        case changedOnDisk(Data)
        case unsupportedText

        var errorDescription: String? {
            switch self {
            case .changedOnDisk: "ファイルが外部で変更されています。"
            case .unsupportedText: "UTF-8テキストとして読み込めません。編集内容は保持されています。"
            }
        }
    }

    func save(overwriting diskData: Data? = nil) throws {
        guard case let .text(source) = content, let savedData else { throw SaveError.unsupportedText }
        let target = fileURL.resolvingSymlinksInPath()
        let current = try Data(contentsOf: target)
        guard current == (diskData ?? savedData) else { throw SaveError.changedOnDisk(current) }
        guard source != savedSource || diskData != nil else { return }
        guard FileManager.default.isWritableFile(atPath: target.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var output = source
        let original = String(data: savedData, encoding: .utf8) ?? ""
        let withoutCRLF = original.replacingOccurrences(of: "\r\n", with: "")
        let lineEnding: String? = if original.contains("\r\n") && !withoutCRLF.contains("\r") && !withoutCRLF.contains("\n") {
            "\r\n"
        } else if !original.contains("\n") && original.contains("\r") {
            "\r"
        } else if !original.contains("\r") {
            "\n"
        } else {
            nil
        }
        if let lineEnding {
            output = source.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: lineEnding)
        }
        var data = Data(output.utf8)
        if savedData.starts(with: [0xef, 0xbb, 0xbf]) { data.insert(contentsOf: [0xef, 0xbb, 0xbf], at: 0) }
        try data.write(to: target, options: .atomic)
        self.savedData = data
        savedSource = source
        diskRevision += 1
        for scrollView in editorViews.values {
            (scrollView.documentView as? NSTextView)?.breakUndoCoalescing()
        }
    }

    func adoptLatest() throws {
        let data = try Data(contentsOf: fileURL)
        guard let source = String(data: data, encoding: .utf8) else { throw SaveError.unsupportedText }
        for scrollView in editorViews.values {
            (scrollView.documentView as? NSTextView)?.breakUndoCoalescing()
        }
        undoManager.removeAllActions()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: source)
        savedData = data
        savedSource = source
        content = .text(source)
        diskRevision += 1
    }
}
