import AppKit
import SwiftUI

struct CodexTextInput: NSViewRepresentable {
    let focus: CodexBookFocus
    @Environment(\.isRetainedPageActive) private var isActive
    @Binding var text: String
    @Binding var selection: NSRange
    let handleKey: (NSEvent) -> Bool
    let pasteImages: ([NSImage]) -> Void

    func makeNSView(context: Context) -> CodexTextView {
        let view = CodexTextView()
        view.bookFocus = focus
        focus.inputView = view
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Codexに依頼する")
        view.setAccessibilityHelp("⌘Enterで送信。⌘Vで画像も貼り付け。/でコマンド、$でSkillを選択。")
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13, weight: .light)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: CodexTextView, context: Context) {
        focus.inputView = view
        let becameActive = isActive && !view.isPageActive
        view.isPageActive = isActive
        if becameActive {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isPageActive, !view.isHiddenOrHasHiddenAncestor else { return }
                view.bookFocus?.activateInput()
            }
        }
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        view.handleKey = handleKey
        view.pasteImages = pasteImages
        if !view.hasMarkedText(), view.string != text {
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            view.insertText(text, replacementRange: range)
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        } else if !view.hasMarkedText(), view.selectedRange() != selection, NSMaxRange(selection) <= (text as NSString).length {
            view.setSelectedRange(selection)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CodexTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let font = view.font else { return nil }
        // SwiftUI probes multiple widths; measurement must not change the live text container.
        let storage = NSTextStorage(attributedString: view.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY, layout.defaultLineHeight(for: font))
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexTextInput
        var isUpdating = false
        init(_ parent: CodexTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let range = view.selectedRange()
            if parent.selection != range { parent.selection = range }
        }
    }
}

final class CodexTextView: NSTextView {
    weak var bookFocus: CodexBookFocus?
    var isPageActive = false
    var handleKey: ((NSEvent) -> Bool)?
    var pasteImages: (([NSImage]) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff] + super.readablePasteboardTypes
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .png || type == .tiff else { return super.readSelection(from: pasteboard, type: type) }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !images.isEmpty, let pasteImages else { return false }
        pasteImages(images)
        return true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: max(newSize.width, 1), height: .greatestFiniteMagnitude)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isPageActive, !isHiddenOrHasHiddenAncestor, window != nil { bookFocus?.activateInput() }
    }
}
