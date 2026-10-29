import AppKit
import Highlighter
import SwiftUI
import WhubGit

@MainActor private let codeHighlighter = Highlighter()

struct CodeEditorView: NSViewRepresentable {
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.explorerFocusNavigation) private var explorerFocus
    let state: FileStore
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [LineDiffHunk]
    var diffLines: [DiffLine]? = nil
    var onScrollView: ((NSScrollView) -> Void)? = nil
    var location: FileLocation? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct HighlightKey: Equatable {
        let source: String
        let language: String?
        let dark: Bool
        let diffLines: [DiffLine]?
    }

    final class Coordinator {
        var highlighted: HighlightKey?
        var didRestorePosition = false
        private weak var storage: NSTextStorage?
        private var observation: NSObjectProtocol?

        func observe(_ storage: NSTextStorage) {
            guard self.storage !== storage else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }
            self.storage = storage
            highlighted = nil
            observation = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
            ) { [weak self] notification in
                if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) {
                    self?.highlighted = nil
                }
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        if let scrollView = state.editorViews.views[editorID] { return scrollView }
        let layoutManager = NSLayoutManager()
        state.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.fileStore = state
        textView.editorID = editorID
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        textView.drawsBackground = false
        textView.isEditable = state.isEditable && !state.isFileOperationLocked
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.importsGraphics = false
        textView.allowsUndo = state.isEditable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        let scrollView = CodeScrollView()
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat(Float.greatestFiniteMagnitude), height: CGFloat(Float.greatestFiniteMagnitude))
        textView.textContainer?.size = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.reservedThicknessForMarkers = 0
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        ruler.update(source: source, hunks: hunks, diffLines: diffLines)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()
        state.editorViews.views[editorID] = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.observe(state.textStorage)
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.explorerFocus = explorerFocus
        textView.location = location
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        guard isActive else { return }
        if !context.coordinator.didRestorePosition {
            textView.restorePosition()
            context.coordinator.didRestorePosition = true
        }
        onScrollView?(scrollView)
        (scrollView.verticalRulerView as? LineNumberRulerView)?.update(source: textView.string, hunks: hunks, diffLines: diffLines)
        guard state.textStorage.string == source,
              !state.editorViews.hasMarkedText else { return }
        let dark = colorScheme == .dark
        let key = HighlightKey(source: source, language: language, dark: dark, diffLines: diffLines)
        guard context.coordinator.highlighted != key else { return }
        codeHighlighter?.setTheme(
            dark ? "night-owl" : "xcode",
            withFont: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName,
            ofSize: 13
        )
        let highlighted = language.flatMap { codeHighlighter?.highlight(source, as: $0) }
            ?? NSAttributedString(
                string: source,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        state.textStorage.beginEditing()
        state.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: state.textStorage.length))
        if highlighted.string == source {
            highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attributes, range, _ in
                state.textStorage.addAttributes(attributes, range: range)
            }
        }
        if let diffLines {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 20
            paragraph.maximumLineHeight = 20
            state.textStorage.addAttribute(.paragraphStyle, value: paragraph,
                                           range: NSRange(location: 0, length: state.textStorage.length))
            var offset = 0
            for line in diffLines {
                let length = line.displayText.utf16.count
                let color: NSColor? = switch line.change {
                case .added: .systemGreen
                case .deleted: .systemRed
                case .modified: .systemOrange
                case nil: nil
                }
                if let color {
                    state.textStorage.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.18),
                                                   range: NSRange(location: offset, length: length))
                }
                offset += length
            }
        }
        state.textStorage.endEditing()
        textView.typingAttributes = attributes
        context.coordinator.highlighted = key
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? CodeTextView)?.savePosition()
    }
}

private final class CodeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard hasVerticalRuler, rulersVisible, let ruler = verticalRulerView else { return }
        let left = ceil(convert(ruler.bounds, from: ruler).maxX)
        var frame = contentView.frame
        frame.size.width = max(0, frame.maxX - left)
        frame.origin.x = left
        contentView.frame = frame
        // The ruler occupies its own area, so it must not also inset the document.
        var insets = contentView.contentInsets
        insets.left = 0
        contentView.contentInsets = insets
    }
}

final class CodeTextView: NSTextView {
    weak var fileStore: FileStore?
    weak var explorerFocus: ExplorerFocusNavigation?
    var location: FileLocation?
    var editorID: String?
    var onEdit: (() -> Void)?
    var diffLines: [DiffLine]?

    func savePosition(includingUnfocused: Bool = false) {
        guard isEditable, !isHiddenOrHasHiddenAncestor, let editorID, let fileStore,
              includingUnfocused || window?.firstResponder === self || fileStore.editorPositions[editorID] != nil,
              let scrollView = enclosingScrollView else { return }
        fileStore.editorPositions[editorID] = FileStore.EditorPosition(
            selectedRanges: selectedRanges.map(\.rangeValue),
            scrollOrigin: scrollView.contentView.bounds.origin
        )
        explorerFocus?.rememberEditorPosition(self)
    }

    func restorePosition() {
        guard !isHiddenOrHasHiddenAncestor, let editorID else { return }
        explorerFocus?.inheritEditorPosition(self)
        guard let position = fileStore?.editorPositions[editorID] else { return }
        let length = (string as NSString).length
        let ranges = position.selectedRanges.map { range in
            let start = min(max(0, range.location), length)
            return NSValue(range: NSRange(location: start, length: min(max(0, range.length), length - start)))
        }
        if !ranges.isEmpty { selectedRanges = ranges }
        if let scrollView = enclosingScrollView {
            if let textContainer { layoutManager?.ensureLayout(for: textContainer) }
            scrollView.contentView.scroll(to: position.scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override func resignFirstResponder() -> Bool {
        savePosition()
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let location { explorerFocus?.onEditorFocus?(location) }
        return accepted
    }

    override func copy(_ sender: Any?) {
        guard let diffLines else { super.copy(sender); return }
        let text = selectedRanges.map { DiffLayout.copiedText(lines: diffLines, range: $0.rangeValue) }.joined()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override var undoManager: UndoManager? { fileStore?.undoManager }

    @objc func saveDocument(_ sender: Any?) {
        fileStore?.saveAction?()
    }

    @objc func undo(_ sender: Any?) { if isEditable { undoManager?.undo() } }
    @objc func redo(_ sender: Any?) { if isEditable { undoManager?.redo() } }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return isEditable && undoManager?.canUndo == true
        case #selector(redo(_:)): return isEditable && undoManager?.canRedo == true
        case #selector(saveDocument(_:)): return isEditable && fileStore?.canSave?() == true
        default: return super.validateMenuItem(menuItem)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        guard isEditable else { return }
        fileStore?.content = .text(string)
        onEdit?()
    }

    override func unmarkText() {
        super.unmarkText()
        guard isEditable else { return }
        fileStore?.content = .text(string)
    }
}

final class CodeEditorViews {
    // shortcut: retain editors until the file closes; evict closed scenes if window churn matters.
    var views: [String: NSScrollView] = [:]

    var hasMarkedText: Bool {
        views.values.contains { ($0.documentView as? NSTextView)?.hasMarkedText() == true }
    }

    func breakUndoCoalescing() {
        for scrollView in views.values {
            (scrollView.documentView as? NSTextView)?.breakUndoCoalescing()
        }
    }
}
