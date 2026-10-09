import AppKit
import Highlighter
import SwiftUI
import WhubCore

@MainActor private let codeHighlighter = Highlighter()

struct CodeEditorView: NSViewRepresentable {
    let state: FileStore
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [LineDiffHunk]
    var diffLines: [DiffLine]? = nil
    var onScrollView: ((NSScrollView) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        if let scrollView = state.editorViews[editorID] { return scrollView }
        let layoutManager = NSLayoutManager()
        state.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.fileStore = state
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        textView.drawsBackground = false
        textView.isEditable = state.isEditable
        textView.isRichText = false
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
        state.editorViews[editorID] = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        onScrollView?(scrollView)
        (scrollView.verticalRulerView as? LineNumberRulerView)?.update(source: textView.string, hunks: hunks, diffLines: diffLines)
        guard state.textStorage.string == source,
              !state.editorViews.values.contains(where: {
                  ($0.documentView as? NSTextView)?.hasMarkedText() == true
              }) else { return }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
    }
}

private final class CodeScrollView: NSScrollView {
    private var didPositionAtLeft = false

    override func tile() {
        super.tile()
        guard !didPositionAtLeft, contentView.bounds.width > 0,
              contentView.contentInsets.left > 0 else { return }
        didPositionAtLeft = true
        contentView.scroll(to: NSPoint(x: -contentView.contentInsets.left, y: contentView.bounds.minY))
        reflectScrolledClipView(contentView)
    }
}

final class CodeTextView: NSTextView {
    weak var fileStore: FileStore?
    var onEdit: (() -> Void)?
    var diffLines: [DiffLine]?

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

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return undoManager?.canUndo == true
        case #selector(redo(_:)): return undoManager?.canRedo == true
        case #selector(saveDocument(_:)): return fileStore?.isEditable == true && fileStore?.canSave?() == true
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
