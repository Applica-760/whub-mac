import AppKit
import Highlighter
import SwiftUI
import WhubCore

@MainActor private let codeHighlighter = Highlighter()

struct CodeEditorView: NSViewRepresentable {
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.colorScheme) private var colorScheme
    let state: FileStore
    let editorID: String
    let onEdit: () -> Void
    let source: String
    let language: String?
    let hunks: [LineDiffHunk]
    var diffLines: [DiffLine]? = nil
    var onScrollView: ((NSScrollView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct HighlightKey: Equatable {
        let source: String
        let language: String?
        let dark: Bool
        let diffLines: [DiffLine]?
    }

    final class Coordinator {
        var highlighted: HighlightKey?
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
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        textView.drawsBackground = false
        textView.isEditable = state.isEditable
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
        textView.onEdit = onEdit
        textView.diffLines = diffLines
        guard isActive else { return }
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

struct LocalCodeEditorView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    let state: LocalFileStore
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
            CodeEditorView(
                state: state.document,
                editorID: editorID,
                onEdit: onEdit,
                source: source,
                language: codeLanguages[fileURL.pathExtension.lowercased()],
                hunks: diffStore.hunks(for: fileURL, source: source)
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID, diskRevision: state.diskRevision)) {
            await diffStore.load(fileURL: fileURL, gitStore: gitStore)
        }
        .task(id: CodeDiffID(baseline: diffStore.baseline, source: source)) {
            await diffStore.update(source: source)
        }
    }
}

struct RemoteViewerView: View {
    @ObservedObject var store: RemoteEditorStore
    let location: FileLocation
    let editorID: String

    var body: some View {
        content
    }

    private var content: some View {
        VStack(spacing: 0) {
            Text("\(store.file(for: location)?.isEditable == true ? "リモート" : "読み取り専用") · \(location.path)")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            switch store.states[location] {
            case .loading:
                ProgressView(store.file(for: location) == nil ? "本文を取得中…" : "本文を再取得中…（表示は前回取得分）")
                    .padding(8)
            case let .failed(message):
                Text("\(message)\n\(store.file(for: location) == nil ? "リロードで再取得できます。" : "本文・編集内容は保持されています。最新状態を確認できません。")")
                    .foregroundStyle(.orange).padding(8)
            case .disconnected:
                Text("切断しました。編集内容は保持されています。")
                    .foregroundStyle(.orange).padding(8)
            case .loaded, nil:
                EmptyView()
            }
            if let remote = store.fileStores[location] {
                if remote.isSaving { ProgressView("保存中…").padding(8) }
                if let message = remote.message { Text(message).foregroundStyle(.orange).padding(8) }
            }
            if let file = store.file(for: location), case let .text(source) = file.content {
                CodeEditorView(state: file, editorID: editorID, onEdit: {}, source: source,
                                language: codeLanguages[(location.name as NSString).pathExtension.lowercased()], hunks: [])
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
