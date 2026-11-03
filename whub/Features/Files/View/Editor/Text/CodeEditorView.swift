import AppKit
import Combine
import SwiftUI
import WhubGit

struct CodeEditorView: NSViewRepresentable {
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.explorerFocusNavigation) private var explorerFocus
    let state: EditContentStore
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [LineDiffHunk]
    var diffLines: [DiffLine]? = nil
    var onScrollView: ((NSScrollView) -> Void)? = nil
    var onExpandDiff: ((Range<Int>) -> Void)? = nil
    var location: FileLocation? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var highlighted: CodeHighlighter.Request?
        var lineNumbersNeedUpdate = true
        var didRestorePosition = false
        private var needsHighlightDelay = false
        private var pending: CodeHighlighter.Request?
        private var highlightTask: Task<Void, Never>?
        private weak var storage: NSTextStorage?
        private var observation: NSObjectProtocol?
        private var activity: RetainedPageActivity?
        private var activitySubscription: AnyCancellable?

        func observeActivity(_ activity: RetainedPageActivity?) {
            guard self.activity !== activity else { return }
            self.activity = activity
            activitySubscription = activity?.isActive.sink { [weak self] active in
                if !active { self?.cancelHighlight() }
            }
        }

        func observe(_ storage: NSTextStorage) {
            guard self.storage !== storage else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }
            self.storage = storage
            cancelHighlight()
            highlighted = nil
            needsHighlightDelay = false
            lineNumbersNeedUpdate = true
            observation = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
            ) { [weak self] notification in
                if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) {
                    self?.needsHighlightDelay = true
                    self?.highlighted = nil
                    self?.cancelHighlight()
                    self?.lineNumbersNeedUpdate = true
                }
            }
        }

        func cancelHighlight() {
            highlightTask?.cancel()
            highlightTask = nil
            pending = nil
        }

        func highlight(_ request: CodeHighlighter.Request, state: EditContentStore, textView: CodeTextView) {
            if highlighted == request {
                cancelHighlight()
                return
            }
            guard pending != request else { return }
            cancelHighlight()
            pending = request
            let delay = needsHighlightDelay
            highlightTask = Task { [weak self, weak state, weak textView] in
                if delay {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
                let result = await CodeHighlighter.shared.highlight(request)
                guard !Task.isCancelled, let self, self.pending == request else { return }
                self.pending = nil
                self.highlightTask = nil
                guard let result, let state, let textView,
                      !textView.isHiddenOrHasHiddenAncestor,
                      !state.editorViews.hasMarkedText,
                      state.textStorage.string == request.source else { return }
                CodeHighlighter.apply(result, to: state.textStorage)
                self.needsHighlightDelay = false
                textView.typingAttributes = [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
                self.highlighted = request
            }
        }

        deinit {
            highlightTask?.cancel()
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
        textView.onExpandDiff = onExpandDiff
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
        context.coordinator.observeActivity(activity)
        context.coordinator.observe(state.textStorage)
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.explorerFocus = explorerFocus
        textView.location = location
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        textView.onExpandDiff = onExpandDiff
        guard isActive, activity?.isActive.value != false else {
            context.coordinator.cancelHighlight()
            return
        }
        if !context.coordinator.didRestorePosition {
            textView.restorePosition()
            context.coordinator.didRestorePosition = true
        }
        onScrollView?(scrollView)
        (scrollView.verticalRulerView as? LineNumberRulerView)?.update(
            source: context.coordinator.lineNumbersNeedUpdate ? textView.string : nil,
            hunks: hunks, diffLines: diffLines
        )
        context.coordinator.lineNumbersNeedUpdate = false
        guard state.textStorage.string == source, !state.editorViews.hasMarkedText else {
            context.coordinator.cancelHighlight()
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.typingAttributes = attributes
        context.coordinator.highlight(
            CodeHighlighter.Request(source: source, language: language, dark: colorScheme == .dark, diffLines: diffLines),
            state: state, textView: textView
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelHighlight()
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
    weak var fileStore: EditContentStore?
    weak var explorerFocus: ExplorerFocusNavigation?
    var location: FileLocation?
    var editorID: String?
    var onEdit: (() -> Void)?
    var diffLines: [DiffLine]?
    var onExpandDiff: ((Range<Int>) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let diffLines, let layoutManager else { super.draw(dirtyRect); return }
        var offset = 0
        let lineWidth = 1 / (window?.backingScaleFactor ?? 1)
        var frames: [NSRect] = []
        for line in diffLines {
            if line.foldedRange != nil, offset < (string as NSString).length {
                let glyph = layoutManager.glyphIndexForCharacter(at: offset)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let frame = NSRect(x: visibleRect.minX, y: fragment.minY + textContainerOrigin.y,
                                   width: visibleRect.width, height: fragment.height).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                if frame.intersects(dirtyRect) { frames.append(frame) }
            }
            offset += line.displayText.utf16.count
        }
        NSColor.separatorColor.withAlphaComponent(0.12).setFill()
        for frame in frames { frame.fill() }
        super.draw(dirtyRect)
        NSColor.separatorColor.setStroke()
        for frame in frames {
            let border = NSBezierPath(rect: frame)
            border.lineWidth = lineWidth
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let diffLines, let onExpandDiff {
            let position = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            var offset = 0
            for line in diffLines {
                let end = offset + line.displayText.utf16.count
                if position >= offset, position < end, let range = line.foldedRange {
                    onExpandDiff(range)
                    return
                }
                offset = end
            }
        }
        super.mouseDown(with: event)
    }

    func savePosition(includingUnfocused: Bool = false) {
        guard isEditable, !isHiddenOrHasHiddenAncestor, let editorID, let fileStore,
              includingUnfocused || window?.firstResponder === self || fileStore.editorPositions[editorID] != nil,
              let scrollView = enclosingScrollView else { return }
        fileStore.editorPositions[editorID] = EditContentStore.EditorPosition(
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
