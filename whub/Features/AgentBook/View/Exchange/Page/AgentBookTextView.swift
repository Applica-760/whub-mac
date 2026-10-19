import AppKit
import SwiftUI

struct AgentBookTextView: NSViewRepresentable {
    @ObservedObject var book: AgentBookPageLayout
    let focus: AgentBookFocus
    let header: (AgentExchange) -> AnyView
    let promptControl: (UUID) -> AnyView
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentBookTextSurface { AgentBookTextSurface(book: book) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentBookTextSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func updateNSView(_ view: AgentBookTextSurface, context: Context) {
        focus.readingView = view
        view.colorScheme = colorScheme
        view.headerContent = header
        view.promptContent = promptControl
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: AgentBookTextSurface, coordinator: ()) {
        if view.isReading(in: view.window) { view.window?.makeFirstResponder(nil) }
    }
}

final class AgentBookTextSurface: NSView, AgentBookReadingSurface {
    private let book: AgentBookPageLayout
    var colorScheme: ColorScheme = .light
    private var pages: [String: NSScrollView] = [:]
    var headerContent: ((AgentExchange) -> AnyView)?
    var promptContent: ((UUID) -> AnyView)?
    private var controlViews: [String: NSHostingView<AnyView>] = [:]
    private var promptViews: [UUID: NSScrollView] = [:]
    private var codeViews: [String: NSHostingView<AgentBookCodeBlock>] = [:]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func isReading(in window: NSWindow?) -> Bool {
        guard let window, self.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.firstResponder === self { return true }
        guard let text = window.firstResponder as? NSTextView, !text.isHiddenOrHasHiddenAncestor else { return false }
        return text.isDescendant(of: self)
    }

    private var activePage: AgentBookNativeTextView? {
        if let text = window?.firstResponder as? AgentBookNativeTextView,
           text.isDescendant(of: self), !text.isHiddenOrHasHiddenAncestor { return text }
        return book.pages.dropFirst(book.spread * 2).prefix(2).compactMap {
            pages[$0.id]?.documentView as? AgentBookNativeTextView
        }.first
    }

    func activateReading() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        window?.makeFirstResponder(activePage ?? self)
    }

    override func mouseDown(with event: NSEvent) { activateReading() }
    @objc func copy(_ sender: Any?) { activePage?.copy(sender) }

    override func selectAll(_ sender: Any?) {
        guard let page = activePage else { return }
        page.setSelectedRange(NSRange(location: 0, length: page.textStorage?.length ?? 0))
        activateReading()
    }

    init(book: AgentBookPageLayout) {
        self.book = book
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let wasReading = isReading(in: window)
        let selections = pages.mapValues { ($0.documentView as? NSTextView)?.selectedRange() ?? NSRange(location: 0, length: 0) }
        let origins = pages.mapValues { $0.contentView.bounds.origin }
        let changed = book.prepare(viewport: bounds.size, colorScheme: colorScheme)
        let liveIDs = Set(book.pages.map(\.id))
        for id in Array(pages.keys) where !liveIDs.contains(id) {
            pages.removeValue(forKey: id)?.removeFromSuperview()
        }
        let livePromptIDs = Set(book.pages.flatMap(\.prompts).map(\.id))
        for id in Array(promptViews.keys) where !livePromptIDs.contains(id) {
            promptViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        promptViews.values.forEach { $0.isHidden = true }
        let liveCodeIDs = Set(book.pages.flatMap(\.codes).map(\.id))
        for id in Array(codeViews.keys) where !liveCodeIDs.contains(id) {
            codeViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        let liveControlIDs = Set(book.headers.map { "header/\($0.id)" } + book.promptControls.map { "prompt/\($0.id)" })
        for id in Array(controlViews.keys) where !liveControlIDs.contains(id) {
            controlViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        controlViews.values.forEach { $0.isHidden = true }
        codeViews.values.forEach { $0.isHidden = true }
        let firstPage = book.spread * 2
        for (index, model) in book.pages.enumerated() {
            let visible = (firstPage..<firstPage + 2).contains(index)
            guard visible || pages[model.id] != nil else { continue }
            let scroll: NSScrollView
            let page: AgentBookNativeTextView
            if let existing = pages[model.id], let text = existing.documentView as? AgentBookNativeTextView {
                scroll = existing
                page = text
            } else {
                scroll = NSScrollView()
                scroll.drawsBackground = false
                scroll.hasVerticalScroller = true
                scroll.hasHorizontalScroller = false
                scroll.autohidesScrollers = true
                scroll.scrollerStyle = .overlay
                page = AgentBookNativeTextView(frame: .zero, textContainer: model.container)
                page.readingSurface = self
                page.isEditable = false
                page.isSelectable = true
                page.isRichText = true
                page.isVerticallyResizable = false
                page.isHorizontallyResizable = false
                page.textContainerInset = NSSize(width: AgentBookPageStyle.pageInset, height: AgentBookPageStyle.pageInset)
                page.drawsBackground = false
                page.autoresizingMask = []
                scroll.documentView = page
                addSubview(scroll)
                pages[model.id] = scroll
            }
            let origin = origins[model.id] ?? .zero
            scroll.frame = NSRect(x: CGFloat(index - firstPage) * (book.pageSize.width + AgentBookPageStyle.pageGap), y: 0,
                                  width: book.pageSize.width, height: book.pageSize.height)
            page.frame.size = NSSize(width: book.pageSize.width,
                                    height: max(scroll.contentSize.height, ceil(model.manager.usedRect(for: model.container).maxY) + 2 * AgentBookPageStyle.pageInset))
            if changed, let selected = selections[model.id] {
                let start = min(selected.location, model.storage.length)
                page.setSelectedRange(NSRange(location: start, length: min(selected.length, model.storage.length - start)))
            }
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(CGRect(origin: origin, size: scroll.contentView.bounds.size)).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.isHidden = !visible
            guard visible else { continue }
            for control in book.headers where control.page == index {
                if let exchange = book.exchange(control.id), let content = headerContent?(exchange) {
                    placeControl("header/\(control.id)", content: content, frame: control.frame, in: page)
                }
            }
            for control in book.promptControls where control.page == index {
                if let content = promptContent?(control.id) {
                    placeControl("prompt/\(control.id)", content: content, frame: control.frame, in: page)
                }
            }
            for prompt in model.prompts {
                let inner: NSScrollView
                let text: NSTextView
                if let existing = promptViews[prompt.id], let document = existing.documentView as? NSTextView {
                    inner = existing
                    text = document
                } else {
                    inner = NSScrollView()
                    inner.drawsBackground = false
                    inner.hasVerticalScroller = true
                    inner.hasHorizontalScroller = false
                    inner.autohidesScrollers = true
                    inner.scrollerStyle = .overlay
                    text = NSTextView(frame: .zero)
                    text.isEditable = false
                    text.isSelectable = true
                    text.isRichText = true
                    text.drawsBackground = false
                    text.textContainerInset = .zero
                    text.textContainer?.lineFragmentPadding = 0
                    text.textContainer?.widthTracksTextView = false
                    text.textContainer?.heightTracksTextView = false
                    text.isVerticallyResizable = false
                    text.isHorizontallyResizable = false
                    inner.documentView = text
                    promptViews[prompt.id] = inner
                }
                if inner.superview !== page { page.addSubview(inner) }
                let promptOrigin = inner.contentView.bounds.origin
                let selection = text.selectedRange()
                if text.attributedString() != prompt.text {
                    text.textStorage?.setAttributedString(prompt.text)
                    let start = min(selection.location, prompt.text.length)
                    text.setSelectedRange(NSRange(location: start, length: min(selection.length, prompt.text.length - start)))
                }
                text.textContainer?.containerSize = CGSize(width: prompt.size.width, height: CGFloat.greatestFiniteMagnitude)
                if let container = text.textContainer, let manager = text.layoutManager {
                    manager.ensureLayout(for: container)
                    text.frame.size = CGSize(width: prompt.size.width, height: max(prompt.size.height, ceil(manager.usedRect(for: container).maxY)))
                }
                let glyphs = model.manager.glyphRange(forCharacterRange: prompt.range, actualCharacterRange: nil)
                let rect = model.manager.boundingRect(forGlyphRange: glyphs, in: model.container)
                inner.frame = CGRect(x: rect.minX + page.textContainerOrigin.x, y: rect.minY + page.textContainerOrigin.y,
                                     width: prompt.size.width, height: prompt.size.height)
                inner.contentView.scroll(to: inner.contentView.constrainBoundsRect(CGRect(origin: promptOrigin, size: inner.contentView.bounds.size)).origin)
                inner.reflectScrolledClipView(inner.contentView)
                inner.isHidden = false
            }
            for code in model.codes {
                let view: NSHostingView<AgentBookCodeBlock>
                if let existing = codeViews[code.id] {
                    view = existing
                    if view.rootView.code != code.text { view.rootView = AgentBookCodeBlock(code: code.text) }
                } else {
                    view = NSHostingView(rootView: AgentBookCodeBlock(code: code.text))
                    codeViews[code.id] = view
                }
                if view.superview !== page { page.addSubview(view) }
                let glyphs = model.manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
                let rect = model.manager.boundingRect(forGlyphRange: glyphs, in: model.container)
                view.frame = NSRect(x: rect.minX + page.textContainerOrigin.x,
                                    y: rect.minY + page.textContainerOrigin.y,
                                    width: code.size.width, height: code.size.height)
                view.isHidden = false
            }
        }
        if wasReading && !isReading(in: window) { activateReading() }
    }

    private func placeControl(_ id: String, content: AnyView, frame: CGRect, in page: NSTextView) {
        let view: NSHostingView<AnyView>
        if let existing = controlViews[id] {
            view = existing
            view.rootView = content
        } else {
            view = NSHostingView(rootView: content)
            controlViews[id] = view
        }
        if view.superview !== page { page.addSubview(view) }
        view.frame = frame
        view.isHidden = false
    }

}

private final class AgentBookNativeTextView: NSTextView {
    weak var readingSurface: AgentBookTextSurface?

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
                text += (attributes[.agentBookPromptSource] as? NSAttributedString)?.string
                    ?? attributes[.agentBookFormulaSource] as? String
                    ?? attributes[.agentBookCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(text, forType: .string)
    }
}

// Keep the existing code-block chrome; AppKit owns text selection and horizontal scrolling.
private struct AgentBookCodeBlock: View {
    let code: String

    var body: some View {
        AgentBookCodeScroll(code: code)
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(AgentBookCodeStyle.codeInset)
            }
    }
}

private struct AgentBookCodeScroll: NSViewRepresentable {
    let code: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = AgentBookCodeScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = AgentBookCodeStyle.codeFont
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: AgentBookCodeStyle.codeInset, height: AgentBookCodeStyle.codeInset)
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
        text.frame.size = NSSize(width: ceil(used.width) + 2 * AgentBookCodeStyle.codeInset, height: ceil(used.height) + 2 * AgentBookCodeStyle.codeInset)
        assert(text.string == code, "Horizontal scrolling must not insert line breaks into the source")
    }
}

private final class AgentBookCodeScrollView: NSScrollView {
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
