import AppKit
import Combine
import Foundation

final class FileStore: ObservableObject {
    enum Content {
        case text(String)
        case binary
        case error(String)
    }

    @Published var content: Content {
        didSet { onContentChange?() }
    }
    @Published private(set) var savedSource: String?
    let isEditable: Bool
    let textStorage: NSTextStorage
    let undoManager = UndoManager()
    // ponytail: retain editors until the file closes; evict closed scenes if window churn matters.
    var editorViews: [String: NSScrollView] = [:]
    var onContentChange: (() -> Void)?
    var saveAction: (() -> Void)?
    var canSave: (() -> Bool)?

    init(content: Content, isEditable: Bool) {
        self.content = content
        self.isEditable = isEditable
        if case let .text(source) = content {
            savedSource = source
            textStorage = NSTextStorage(string: source)
        } else {
            savedSource = nil
            textStorage = NSTextStorage()
        }
    }

    convenience init(source: String) {
        self.init(content: .text(source), isEditable: false)
    }

    func updateReadOnly(source: String) {
        guard !isEditable, source != savedSource else { return }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: source)
        savedSource = source
        content = .text(source)
    }

    var hasUnsavedChanges: Bool {
        guard isEditable, case let .text(source) = content else { return false }
        return source != savedSource
    }

    func markSaved(source: String) {
        savedSource = source
        for scrollView in editorViews.values {
            (scrollView.documentView as? NSTextView)?.breakUndoCoalescing()
        }
    }

    func replace(source: String) {
        markSaved(source: source)
        undoManager.removeAllActions()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: source)
        content = .text(source)
    }
}
