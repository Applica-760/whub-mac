import AppKit
import SwiftUI

enum MarkdownCodeStyle {
    static let codeInset: CGFloat = 12
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static var codeLineHeight: CGFloat { ceil(codeFont.ascender - codeFont.descender + codeFont.leading) }
}

// Keep the existing code-block chrome; AppKit owns text selection and horizontal scrolling.
struct MarkdownCodeBlock: View {
    let code: String

    var body: some View {
        MarkdownCodeScroll(code: code)
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .accessibilityIdentifier("markdown.code.copy")
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(MarkdownCodeStyle.codeInset)
            }
    }
}

private struct MarkdownCodeScroll: NSViewRepresentable {
    let code: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownCodeScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = MarkdownCodeStyle.codeFont
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: MarkdownCodeStyle.codeInset, height: MarkdownCodeStyle.codeInset)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != code {
            let selection = text.selectedRange()
            let origin = scroll.contentView.bounds.origin
            text.string = code
            let start = min(selection.location, (code as NSString).length)
            text.setSelectedRange(NSRange(location: start, length: min(selection.length, (code as NSString).length - start)))
            scroll.contentView.scroll(to: origin)
        }
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        var width: CGFloat = 0
        // With a trailing newline, usedRect can include the oversized extra line fragment.
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, used, _, _, _ in
            width = max(width, used.maxX)
        }
        text.frame.size = NSSize(width: ceil(width) + 2 * MarkdownCodeStyle.codeInset, height: ceil(used.height) + 2 * MarkdownCodeStyle.codeInset)
        assert(text.string == code, "Horizontal scrolling must not insert line breaks into the source")
    }
}

private final class MarkdownCodeScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    scroll.scrollWheel(with: event)
                    return
                }
                ancestor = view.superview
            }
        }
        super.scrollWheel(with: event)
    }
}
