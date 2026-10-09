import AppKit
import Highlighter
import SwiftUI
import WhubCore

struct CodeViewerView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    let state: FileStore
    let editorID: String
    let onEdit: () -> Void
    @EnvironmentObject private var gitStore: GitStore
    @StateObject private var diffStore = GitLineStore()

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = diffStore.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
            CodeTextContent(
                state: state,
                editorID: editorID,
                onEdit: onEdit,
                source: source,
                language: codeLanguages[fileURL.pathExtension.lowercased()],
                hunks: diffStore.hunks(for: fileURL, source: source)
            )
        }
        .background(Color(white: 0.07).opacity(0.75))
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID, diskRevision: state.diskRevision)) {
            await diffStore.load(fileURL: fileURL, gitStore: gitStore)
        }
        .task(id: CodeDiffID(baseline: diffStore.baseline, source: source)) {
            await diffStore.update(source: source)
        }
    }
}

private struct CodeDiffID: Equatable {
    let baseline: GitLineStore.Baseline?
    let source: String
}

private struct CodeLoadID: Equatable {
    let fileURL: URL
    let refreshID: Int
    let diskRevision: Int
}

@MainActor private let codeHighlighter = Highlighter()

struct CodeTextContent: NSViewRepresentable {
    let state: FileStore
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [LineDiffHunk]

    func makeNSView(context: Context) -> NSScrollView {
        if let scrollView = state.editorViews[editorID] { return scrollView }
        let layoutManager = NSLayoutManager()
        state.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.fileStore = state
        textView.onEdit = onEdit
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
        ruler.update(source: source, hunks: hunks)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.tile()
        state.editorViews[editorID] = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.onEdit = onEdit
        (scrollView.verticalRulerView as? LineNumberRulerView)?.update(source: textView.string, hunks: hunks)
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

    override var undoManager: UndoManager? { fileStore?.undoManager }

    @objc func saveDocument(_ sender: Any?) {
        fileStore?.saveWithConfirmation()
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return undoManager?.canUndo == true
        case #selector(redo(_:)): return undoManager?.canRedo == true
        case #selector(saveDocument(_:)): return fileStore?.isEditable == true && fileStore?.savedSource != nil && fileStore?.isSaving != true
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
