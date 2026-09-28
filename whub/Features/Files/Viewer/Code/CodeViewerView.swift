import AppKit
import Highlighter
import SwiftUI
import WhubCore

struct CodeViewerView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    let state: FileState
    let editorID: String
    let onEdit: () -> Void
    @State private var diffURL: URL?
    @State private var hunks: [GitDiffHunk] = []
    @State private var diffErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let diffErrorMessage {
                Text(diffErrorMessage)
                    .foregroundStyle(.secondary)
            }
            Content(
                state: state,
                editorID: editorID,
                onEdit: onEdit,
                source: source,
                language: codeLanguages[fileURL.pathExtension.lowercased()],
                hunks: diffURL == fileURL && source == state.loadedSource ? hunks : []
            )
        }
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID)) {
            diffURL = nil
            hunks = []
            diffErrorMessage = nil
            do {
                let loaded = try await Git.diff(at: fileURL)
                guard !Task.isCancelled else { return }
                hunks = loaded
                diffURL = fileURL
            } catch GitError.notRepository {
                return
            } catch {
                guard !Task.isCancelled else { return }
                diffErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CodeLoadID: Equatable {
    let fileURL: URL
    let refreshID: Int
}

@MainActor private let codeHighlighter = Highlighter()

private struct Content: NSViewRepresentable {
    let state: FileState
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [GitDiffHunk]

    func makeNSView(context: Context) -> NSScrollView {
        if let scrollView = state.editorViews[editorID] { return scrollView }
        let layoutManager = NSLayoutManager()
        state.textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.fileState = state
        textView.onEdit = onEdit
        textView.isEditable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat(Float.greatestFiniteMagnitude), height: CGFloat(Float.greatestFiniteMagnitude))
        textView.textContainer?.size = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let ruler = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.ruleThickness = 30
        ruler.reservedThicknessForMarkers = 0
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
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
            dark ? "xcode-dusk" : "xcode",
            withFont: "Menlo-Regular",
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

private final class CodeTextView: NSTextView {
    weak var fileState: FileState?
    var onEdit: (() -> Void)?

    override var undoManager: UndoManager? { fileState?.undoManager }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return undoManager?.canUndo == true
        case #selector(redo(_:)): return undoManager?.canRedo == true
        default: return super.validateMenuItem(menuItem)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        fileState?.content = .text(string)
        onEdit?()
    }

    override func unmarkText() {
        super.unmarkText()
        fileState?.content = .text(string)
    }
}
