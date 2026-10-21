import AppKit
import QuartzCore
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
    private var readingOrigins: [String: CGPoint] = [:]
    private var readingPageID: String?
    var headerContent: ((AgentExchange) -> AnyView)?
    var promptContent: ((UUID) -> AnyView)?
    private var controlViews: [String: NSHostingView<AnyView>] = [:]
    private var promptViews: [UUID: NSScrollView] = [:]
    private var codeViews: [String: NSHostingView<MarkdownCodeBlock>] = [:]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func isReading(in window: NSWindow?) -> Bool {
        guard let window, self.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.firstResponder === self { return true }
        guard let view = window.firstResponder as? NSView, !view.isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = view
        while let current = ancestor, current !== self {
            if (current as? AgentBookPageScrollView)?.isPreview == true { return false }
            ancestor = current.superview
        }
        return view.isDescendant(of: self)
    }

    private func selectResponderPage() {
        guard let responder = window?.firstResponder as? NSView, responder !== self else { return }
        for (index, model) in book.pages.enumerated() {
            guard index == book.selectedPage else { continue }
            guard let scroll = pages[model.id], !scroll.isHidden else { continue }
            if responder === scroll || responder.isDescendant(of: scroll) {
                book.selectPage(index)
                return
            }
        }
    }

    private var activePage: AgentBookNativeTextView? {
        guard book.pages.indices.contains(book.selectedPage) else { return nil }
        return pages[book.pages[book.selectedPage].id]?.documentView as? AgentBookNativeTextView
    }

    func activateReading() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        selectResponderPage()
        window?.makeFirstResponder(self)
    }

    func movePage(_ offset: Int) {
        selectResponderPage()
        book.move(offset)
        window?.makeFirstResponder(self)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func scrollPage(_ offset: Int) {
        selectResponderPage()
        layoutSubtreeIfNeeded()
        let first = book.selectedPage
        guard book.pages.indices.contains(first) else { return }
        let lineHeight = book.pages[first].manager.defaultLineHeight(for: NSFont.systemFont(ofSize: 15)) + 4
        let distance = CGFloat(offset) * 3 * lineHeight
        for model in book.pages.dropFirst(first).prefix(1) {
            guard let scroll = pages[model.id], !scroll.isHidden else { continue }
            var target = scroll.contentView.bounds
            target.origin.y += distance
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
    @objc func copy(_ sender: Any?) {
        selectResponderPage()
        activePage?.copy(sender)
    }

    override func selectAll(_ sender: Any?) {
        selectResponderPage()
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
        if let readingPageID, let scroll = pages[readingPageID] {
            readingOrigins[readingPageID] = scroll.contentView.bounds.origin
        }
        let previousPage = readingPageID.flatMap { id in book.pages.firstIndex { $0.id == id } }
        let changed = book.prepare(viewport: bounds.size, colorScheme: colorScheme)
        let animatesNavigation = previousPage != nil && previousPage != book.selectedPage
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let liveIDs = Set(book.pages.map(\.id))
        for id in Array(pages.keys) where !liveIDs.contains(id) {
            pages.removeValue(forKey: id)?.removeFromSuperview()
            readingOrigins.removeValue(forKey: id)
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
        var visibleCodeIDs = Set<String>()
        for (index, model) in book.pages.enumerated() {
            let visible = book.visiblePages.contains(index)
            guard visible || pages[model.id] != nil else { continue }
            let scroll: NSScrollView
            let page: AgentBookNativeTextView
            if let existing = pages[model.id], let text = existing.documentView as? AgentBookNativeTextView {
                scroll = existing
                page = text
            } else {
                scroll = AgentBookPageScrollView()
                scroll.isHidden = true
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
                page.textContainerInset = NSSize(width: AgentBookPageStyle.horizontalInset, height: AgentBookPageStyle.pageInset)
                page.drawsBackground = false
                page.autoresizingMask = []
                scroll.documentView = page
                addSubview(scroll)
                pages[model.id] = scroll
            }
            let origin = readingOrigins[model.id] ?? .zero
            let size = book.size(for: index)
            let isPreview = index != book.selectedPage
            (scroll as? AgentBookPageScrollView)?.isPreview = isPreview
            scroll.setAccessibilityHidden(!visible || isPreview)
            do {
                scroll.drawsBackground = true
                scroll.backgroundColor = .windowBackgroundColor
                scroll.wantsLayer = true
                scroll.layer?.cornerRadius = 14
                scroll.layer?.masksToBounds = true
                scroll.layer?.borderWidth = 1
                scroll.layer?.borderColor = NSColor.separatorColor.cgColor
                scroll.layer?.zPosition = isPreview ? 0 : 1
            }
            (scroll as? AgentBookPageScrollView)?.updatePresentation(
                side: index == book.selectedPage ? 0 : (index < book.selectedPage ? -1 : 1),
                frame: CGRect(origin: book.pageOrigin(index, viewport: bounds.size), size: book.displaySize(for: index)),
                logicalSize: size,
                animated: animatesNavigation && visible
            )
            page.frame.size = NSSize(width: size.width,
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
                visibleCodeIDs.insert(code.id)
                let view: NSHostingView<MarkdownCodeBlock>
                if let existing = codeViews[code.id] {
                    view = existing
                    if view.rootView.code != code.text { view.rootView = MarkdownCodeBlock(code: code.text) }
                } else {
                    view = NSHostingView(rootView: MarkdownCodeBlock(code: code.text))
                    codeViews[code.id] = view
                }
                if view.superview !== page { page.addSubview(view) }
                let glyphs = model.manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
                let rect = model.manager.boundingRect(forGlyphRange: glyphs, in: model.container)
                view.frame = NSRect(x: rect.minX + page.textContainerOrigin.x,
                                    y: rect.minY + page.textContainerOrigin.y,
                                    width: code.size.width, height: code.size.height)
            }
        }
        for (id, view) in codeViews {
            let hidden = !visibleCodeIDs.contains(id)
            if view.isHidden != hidden { view.isHidden = hidden }
        }
        readingPageID = book.pages.indices.contains(book.selectedPage) ? book.pages[book.selectedPage].id : nil
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

private final class AgentBookPageScrollView: NSScrollView {
    var isPreview = false
    private let dimmingLayer = CALayer()

    func updatePresentation(side: Int, frame: CGRect, logicalSize: CGSize, animated: Bool) {
        guard let layer else { return }
        let wasHidden = isHidden
        let previous = layer.presentation() ?? layer
        let previousPosition = previous.position
        let previousTransform = previous.transform
        let previousOpacity = (dimmingLayer.presentation() ?? dimmingLayer).opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        bounds.size = logicalSize
        // AppKit defaults to a top-left pivot; a centered pivot makes left/right projection symmetric.
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        if dimmingLayer.superlayer !== layer {
            dimmingLayer.zPosition = 1000
            layer.addSublayer(dimmingLayer)
        }
        dimmingLayer.frame = bounds
        dimmingLayer.opacity = isPreview ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dimmingLayer.backgroundColor = NSColor.systemGray.withAlphaComponent(0.18).cgColor
        }
        var transform = CATransform3DIdentity
        if isPreview {
            transform.m34 = -1 / AgentBookPageStyle.perspectiveDistance(pageWidth: bounds.width)
            transform = CATransform3DRotate(transform, CGFloat(side) * AgentBookPageStyle.previewAngle, 0, 1, 0)
        }
        let scale = frame.width / logicalSize.width
        layer.transform = CATransform3DScale(transform, scale, scale, 1)
        if animated {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: wasHidden
                ? CGPoint(x: layer.position.x + CGFloat(side) * frame.width, y: layer.position.y)
                : previousPosition)
            position.toValue = NSValue(point: layer.position)
            let rotation = CABasicAnimation(keyPath: "transform")
            rotation.fromValue = NSValue(caTransform3D: wasHidden ? layer.transform : previousTransform)
            rotation.toValue = NSValue(caTransform3D: layer.transform)
            let shade = CABasicAnimation(keyPath: "opacity")
            shade.fromValue = previousOpacity
            shade.toValue = dimmingLayer.opacity
            for animation in [position, rotation, shade] {
                animation.duration = 0.22
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            layer.add(position, forKey: "pagePosition")
            layer.add(rotation, forKey: "pageTransform")
            dimmingLayer.add(shade, forKey: "pageShade")
        }
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isPreview ? nil : super.hitTest(point)
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
                    ?? attributes[.markdownFormulaSource] as? String
                    ?? attributes[.markdownCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(text, forType: .string)
    }
}
