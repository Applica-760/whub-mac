import AppKit
import SwiftUI

struct MarkdownView: NSViewRepresentable {
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSScrollView { MarkdownScrollView() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? MarkdownScrollView)?.update(source: source, colorScheme: colorScheme)
    }
}

private final class MarkdownScrollView: NSScrollView {
    private let storage: NSTextStorage
    private let manager: MarkdownLayoutManager
    private let container: NSTextContainer
    private let text: MarkdownTextView
    private var codeViews: [Int: NSHostingView<MarkdownCodeBlock>] = [:]
    private var source = ""
    private var colorScheme: ColorScheme = .light
    private var renderedSource: String?
    private var renderedWidth: CGFloat = 0
    private var renderedScheme: ColorScheme?
    private var isRendering = false

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let manager = MarkdownLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        self.storage = storage
        self.manager = manager
        self.container = container
        text = MarkdownTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        documentView = text
        text.setAccessibilityLabel("Markdown Preview")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(source: String, colorScheme: ColorScheme) {
        self.source = source
        self.colorScheme = colorScheme
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !isRendering, contentSize.width > 0 else { return }
        isRendering = true
        defer { isRendering = false }
        let width = max(1, contentSize.width - 2 * text.textContainerInset.width)
        if source != renderedSource || width != renderedWidth || colorScheme != renderedScheme {
            let selection = text.selectedRanges
            let origin = contentView.bounds.origin
            let document = MarkdownDocument(source: source, width: width, colorScheme: colorScheme)
            let output = NSMutableAttributedString(attributedString: document.text)
            for code in document.codes {
                if let attachment = output.attribute(.attachment, at: code.range.location, effectiveRange: nil) as? NSTextAttachment {
                    attachment.attachmentCell = MarkdownCodeCell()
                }
            }
            storage.setAttributedString(output)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            resizeText()
            for index in codeViews.keys.filter({ $0 >= document.codes.count }) {
                codeViews.removeValue(forKey: index)?.removeFromSuperview()
            }
            for (index, code) in document.codes.enumerated() {
                let view: NSHostingView<MarkdownCodeBlock>
                if let existing = codeViews[index] {
                    view = existing
                    if view.rootView.code != code.text { view.rootView = MarkdownCodeBlock(code: code.text) }
                } else {
                    view = NSHostingView(rootView: MarkdownCodeBlock(code: code.text))
                    codeViews[index] = view
                    text.addSubview(view)
                }
                let glyphs = manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                view.frame = NSRect(x: rect.minX + text.textContainerOrigin.x,
                                    y: rect.minY + text.textContainerOrigin.y,
                                    width: code.size.width, height: code.size.height)
            }
            text.selectedRanges = selection.map {
                let range = $0.rangeValue
                let start = min(range.location, storage.length)
                return NSValue(range: NSRange(location: start, length: min(range.length, storage.length - start)))
            }
            contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
            reflectScrolledClipView(contentView)
            renderedSource = source
            renderedWidth = width
            renderedScheme = colorScheme
        } else {
            resizeText()
        }
    }

    private func resizeText() {
        text.frame.size = NSSize(width: contentSize.width,
                                 height: max(contentSize.height, ceil(manager.usedRect(for: container).maxY) + 2 * text.textContainerInset.height))
    }
}

private final class MarkdownTextView: NSTextView {
    override func accessibilityChildren() -> [Any]? {
        // NSTextView exposes attachment cells but omits the views overlaid on them.
        (super.accessibilityChildren() ?? []) + subviews.filter { $0 is NSHostingView<MarkdownCodeBlock> }
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        var result = ""
        for selection in selectedRanges {
            storage.enumerateAttributes(in: selection.rangeValue) { attributes, range, _ in
                result += attributes[.markdownFormulaSource] as? String
                    ?? attributes[.markdownCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(result, forType: .string)
    }
}

private final class MarkdownCodeCell: NSTextAttachmentCell {
    nonisolated override func cellSize() -> NSSize { attachment?.bounds.size ?? .zero }

    // The code view draws the content; TextKit reserves its space.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}
