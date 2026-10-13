import AppKit
import SwiftUI

struct CodexBookTextView: NSViewRepresentable {
    @ObservedObject var book: CodexBookDocument
    let focus: CodexBookFocus
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> CodexBookTextSurface { CodexBookTextSurface(book: book) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodexBookTextSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func updateNSView(_ view: CodexBookTextSurface, context: Context) {
        focus.readingView = view
        view.colorScheme = colorScheme
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: CodexBookTextSurface, coordinator: ()) {
        if view.isReading(in: view.window) { view.window?.makeFirstResponder(nil) }
    }
}

final class CodexBookTextSurface: NSView {
    private let book: CodexBookDocument
    var colorScheme: ColorScheme = .light
    private var pages: [CodexBookNativeTextView] = []
    private var codeViews: [String: NSHostingView<CodexBookCodeBlock>] = [:]
    private var navigationRevision = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func isReading(in window: NSWindow?) -> Bool {
        guard let window, self.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.firstResponder === self { return true }
        guard let text = window.firstResponder as? NSTextView, !text.isHiddenOrHasHiddenAncestor else { return false }
        return text.isDescendant(of: self)
    }

    func activateReading() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        if let page = pages.first(where: { !$0.isHidden }) { window?.makeFirstResponder(page) }
        else { window?.makeFirstResponder(self) }
    }

    override func mouseDown(with event: NSEvent) { activateReading() }
    @objc func copy(_ sender: Any?) { pages.first(where: { !$0.isHidden })?.copy(sender) }

    override func selectAll(_ sender: Any?) {
        let first = book.spread * 2
        guard book.ranges.indices.contains(first), let page = pages.first(where: { !$0.isHidden }) else { return }
        let start = book.ranges[first].location
        let end = NSMaxRange(book.ranges[min(first + 1, book.ranges.count - 1)])
        page.setSelectedRange(NSRange(location: start, length: end - start))
        activateReading()
    }

    init(book: CodexBookDocument) {
        self.book = book
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let wasReading = isReading(in: window)
        let selected = pages.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        let startAnchor = book.anchor(at: selected.location)
        let endAnchor = book.anchor(at: NSMaxRange(selected))
        let changed = book.prepare(viewport: bounds.size, colorScheme: colorScheme)
        let containers = book.manager.textContainers
        while pages.count > containers.count { pages.removeLast().removeFromSuperview() }
        while pages.count < containers.count {
            let page = CodexBookNativeTextView(frame: .zero, textContainer: containers[pages.count])
            page.readingSurface = self
            page.isEditable = false
            page.isSelectable = true
            page.isRichText = true
            page.isVerticallyResizable = false
            page.isHorizontallyResizable = false
            page.textContainerInset = NSSize(width: CodexBookLayout.pageInset, height: CodexBookLayout.pageInset)
            page.drawsBackground = false
            page.autoresizingMask = []
            addSubview(page)
            pages.append(page)
        }
        if changed, let first = pages.first {
            let start = min(startAnchor.flatMap { book.location(of: $0) } ?? selected.location, book.storage.length)
            let end = min(endAnchor.flatMap { book.location(of: $0) } ?? NSMaxRange(selected), book.storage.length)
            first.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        }
        let firstPage = min(book.spread * 2, max(0, pages.count - 1))
        for (index, page) in pages.enumerated() {
            page.isHidden = !(firstPage..<firstPage + 2).contains(index)
            if !page.isHidden {
                page.frame = NSRect(x: CGFloat(index - firstPage) * (book.pageSize.width + CodexBookLayout.pageGap), y: 0,
                                    width: book.pageSize.width, height: book.pageSize.height)
            }
        }
        if navigationRevision != book.navigationRevision {
            navigationRevision = book.navigationRevision
            pages.first?.setSelectedRange(NSRange(location: 0, length: 0))
            if wasReading { activateReading() }
        } else if wasReading && !isReading(in: window) {
            activateReading()
        }
        let liveIDs = Set(book.codes.map(\.id))
        for id in Array(codeViews.keys) where !liveIDs.contains(id) {
            codeViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        codeViews.values.forEach { $0.isHidden = true }
        for code in book.codes {
            guard let pageIndex = book.ranges.firstIndex(where: { NSLocationInRange(code.range.location, $0) }),
                  pages.indices.contains(pageIndex), !pages[pageIndex].isHidden else { continue }
            let page = pages[pageIndex]
            guard let container = page.textContainer else { continue }
            let view: NSHostingView<CodexBookCodeBlock>
            if let existing = codeViews[code.id] {
                view = existing
                if view.rootView.code != code.text { view.rootView = CodexBookCodeBlock(code: code.text) }
            } else {
                view = NSHostingView(rootView: CodexBookCodeBlock(code: code.text))
                codeViews[code.id] = view
            }
            if view.superview !== page { page.addSubview(view) }
            let glyphs = book.manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
            let rect = book.manager.boundingRect(forGlyphRange: glyphs, in: container)
            view.frame = NSRect(x: rect.minX + page.textContainerOrigin.x,
                                y: rect.minY + page.textContainerOrigin.y,
                                width: code.size.width, height: code.size.height)
            view.isHidden = false
        }
    }
}

private final class CodexBookNativeTextView: NSTextView {
    weak var readingSurface: CodexBookTextSurface?

    override func selectAll(_ sender: Any?) {
        if let readingSurface { readingSurface.selectAll(sender) } else { super.selectAll(sender) }
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        var text = ""
        for value in selectedRanges {
            storage.enumerateAttributes(in: value.rangeValue) { attributes, range, _ in
                text += attributes[.codexFormulaSource] as? String
                    ?? attributes[.codexBookCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(text, forType: .string)
    }
}

// Keep the existing code-block chrome; AppKit owns text selection and horizontal scrolling.
private struct CodexBookCodeBlock: View {
    let code: String

    var body: some View {
        CodexBookCodeScroll(code: code)
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(CodexBookLayout.codeInset)
            }
    }
}

private struct CodexBookCodeScroll: NSViewRepresentable {
    let code: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = CodexBookLayout.codeFont
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: CodexBookLayout.codeInset, height: CodexBookLayout.codeInset)
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
        text.frame.size = NSSize(width: ceil(used.width) + 2 * CodexBookLayout.codeInset, height: ceil(used.height) + 2 * CodexBookLayout.codeInset)
        assert(text.string == code, "Horizontal scrolling must not insert line breaks into the source")
    }
}
