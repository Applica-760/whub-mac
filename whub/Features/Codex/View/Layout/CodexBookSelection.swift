import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var codexBookSelection: CodexBookSelection? = nil
    @Entry var codexSelectionOrder: [Int] = []
    @Entry var codexSelectionSource: String = ""
}

@MainActor
final class CodexBookSelection {
    let texts = NSHashTable<CodexSelectableTextView>.weakObjects()
    let exclusions = NSHashTable<NSView>.weakObjects()
    weak var surface: NSView?
    fileprivate var anchor: (view: CodexSelectableTextView, index: Int)?
    var orderedTexts: [CodexSelectableTextView] {
        texts.allObjects.filter { $0.window === surface?.window && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.readingOrder.lexicographicallyPrecedes($1.readingOrder) }
    }

    func clear() {
        for view in texts.allObjects { view.highlight(NSRange(location: 0, length: 0)) }
        anchor = nil
    }

    func remove(_ view: CodexSelectableTextView) {
        if anchor?.view === view { clear() }
        texts.remove(view)
    }

    fileprivate func nearest(to point: NSPoint) -> (view: CodexSelectableTextView, index: Int)? {
        guard let surface else { return nil }
        let candidates = orderedTexts.filter { !$0.bounds.intersection($0.visibleRect).isEmpty && $0.textStorage!.length > 0 }
        let local = surface.convert(point, from: nil)
        let page = local.x < surface.bounds.midX
        let onPage = candidates.filter {
            (surface.convert($0.bounds, from: $0).midX < surface.bounds.midX) == page
        }
        let view = (onPage.isEmpty ? candidates : onPage).min { lhs, rhs in
            @MainActor func distance(_ view: NSView) -> CGFloat {
                let rect = view.convert(view.bounds.intersection(view.visibleRect), to: nil)
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                return dx * dx + dy * dy
            }
            return distance(lhs) < distance(rhs)
        }
        guard let view else { return nil }
        let index = view.characterIndexForInsertion(at: view.convert(point, from: nil))
        return (view, min(index, view.textStorage!.length))
    }

    func select(from start: (view: CodexSelectableTextView, index: Int),
                to end: (view: CodexSelectableTextView, index: Int)) {
        let views = orderedTexts
        guard let a = views.firstIndex(where: { $0 === start.view }),
              let b = views.firstIndex(where: { $0 === end.view }) else { return }
        let forward = a < b || (a == b && start.index <= end.index)
        let first = forward ? start : end, last = forward ? end : start
        let lower = min(a, b), upper = max(a, b)
        for (index, view) in views.enumerated() {
            if (lower...upper).contains(index) {
                let length = view.textStorage!.length
                let begin = min(index == lower ? first.index : 0, length)
                let finish = min(index == upper ? last.index : length, length)
                view.highlight(NSRange(location: begin, length: max(0, finish - begin)))
            } else { view.highlight(NSRange(location: 0, length: 0)) }
        }
    }

    var selectedString: String {
        var result = ""
        var previousSource: String?
        for view in orderedTexts where view.selectedRange().length > 0 {
            if !result.isEmpty && (view.sourceID.isEmpty || previousSource != view.sourceID) { result += "\n\n" }
            result += view.plainText(in: view.selectedRange())
            previousSource = view.sourceID
        }
        return result
    }

    func copy() {
        let text = selectedString
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func selectAll() {
        let views = orderedTexts
        guard let first = views.first, let last = views.last else { return }
        anchor = (first, 0)
        select(from: (first, 0), to: (last, last.textStorage!.length))
    }


}

extension NSAttributedString.Key {
    static let codexFormulaSource = NSAttributedString.Key("whub.formulaSource")
}

struct CodexSelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var wraps = true
    @Environment(\.codexBookSelection) private var selection
    @Environment(\.codexSelectionOrder) private var order
    @Environment(\.codexSelectionSource) private var sourceID

    func makeNSView(context: Context) -> CodexSelectableTextView {
        let view = CodexSelectableTextView()
        view.textContainer?.replaceLayoutManager(CodexSelectionLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor]
        return view
    }

    func updateNSView(_ view: CodexSelectableTextView, context: Context) {
        if view.bookSelection !== selection {
            view.bookSelection?.remove(view)
            view.bookSelection = selection
            selection?.texts.add(view)
        }
        view.readingOrder = order
        view.sourceID = sourceID
        if view.textStorage?.isEqual(to: text) != true {
            if view.selectedRange().length > 0 { selection?.clear() }
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CodexSelectableTextView, context: Context) -> CGSize? {
        let width = wraps ? proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil } : nil
        // Measure independently: NSTextView can resize its container during SwiftUI size probes.
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width ?? 100000, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let rect = manager.usedRect(for: container)
        return CGSize(width: width ?? ceil(rect.width), height: max(1, ceil(rect.height)))
    }

    static func dismantleNSView(_ view: CodexSelectableTextView, coordinator: ()) { view.bookSelection?.remove(view) }
}

final class CodexSelectableTextView: NSTextView {
    weak var bookSelection: CodexBookSelection?
    var readingOrder: [Int] = []
    var sourceID = ""

    func plainText(in range: NSRange) -> String {
        guard let storage = textStorage else { return "" }
        var result = ""
        storage.enumerateAttribute(.codexFormulaSource, in: range) { formula, part, _ in
            result += formula as? String ?? (storage.string as NSString).substring(with: part)
        }
        return result
    }

    override func accessibilityValue() -> String? {
        plainText(in: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self,
           let surface = bookSelection?.surface, surface.window === window,
           !surface.isHiddenOrHasHiddenAncestor {
            window.makeFirstResponder(surface)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        textContainer?.containerSize = CGSize(width: max(1, size.width), height: .greatestFiniteMagnitude)
    }

    func highlight(_ range: NSRange) {
        guard let storage = textStorage, let manager = layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        setSelectedRange(range)
        if range.length > 0 {
            manager.addTemporaryAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor,
                                             .foregroundColor: NSColor.selectedTextColor], forCharacterRange: range)
        }
    }

    override func copy(_ sender: Any?) {
        if let bookSelection { bookSelection.copy() } else { super.copy(sender) }
    }
    override func selectAll(_ sender: Any?) {
        if let bookSelection { bookSelection.selectAll() } else { super.selectAll(sender) }
    }
}

// The reading surface owns focus; selection only owns selected content.
@MainActor
final class CodexBookFocus {
    weak var readingView: CodexBookSurfaceView?
    weak var inputView: NSView?

    func isReading(in window: NSWindow) -> Bool {
        guard let readingView, readingView.window === window, !readingView.isHiddenOrHasHiddenAncestor else { return false }
        if window.firstResponder === readingView { return true }
        guard let text = window.firstResponder as? CodexSelectableTextView else { return false }
        return text.bookSelection === readingView.selection
    }

    func activateReading() {
        guard let readingView, !readingView.isHiddenOrHasHiddenAncestor else { return }
        readingView.window?.makeFirstResponder(readingView)
    }

    func activateInput() {
        guard let inputView, !inputView.isHiddenOrHasHiddenAncestor else { return }
        inputView.window?.makeFirstResponder(inputView)
    }
}

struct CodexSelectionSurface: NSViewRepresentable {
    let selection: CodexBookSelection
    let focus: CodexBookFocus
    let bottomInset: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CodexBookSurfaceView {
        let view = CodexBookSurfaceView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak view] event in
            view?.handle(event) == true ? nil : event
        }
        return view
    }
    func updateNSView(_ view: CodexBookSurfaceView, context: Context) {
        selection.surface = view
        view.selection = selection
        view.bottomInset = bottomInset
        focus.readingView = view
    }
    static func dismantleNSView(_ view: CodexBookSurfaceView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator { var monitor: Any? }
}

final class CodexBookSurfaceView: NSView {
    weak var selection: CodexBookSelection?
    var bottomInset: CGFloat = 64
    private var pressedLink: URL?
    private var downPoint = NSPoint.zero
    private var dragging = false
    private var tracking = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    @objc func copy(_ sender: Any?) { selection?.copy() }
    override func selectAll(_ sender: Any?) { selection?.selectAll() }

    func handle(_ event: NSEvent) -> Bool {
        guard let selection, let window, window.isKeyWindow,
              event.window === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return false }
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            let local = convert(point, from: nil)
            guard bounds.contains(local), local.y < bounds.height - bottomInset,
                  !selection.exclusions.allObjects.contains(where: { $0.convert($0.bounds, to: nil).contains(point) }) else { return false }
            guard let target = selection.nearest(to: point) else {
                selection.clear()
                window.makeFirstResponder(self)
                return true
            }
            pressedLink = nil
            dragging = false
            tracking = false
            if event.clickCount > 1 { selection.clear(); return false }
            let previous = selection.anchor
            selection.clear()
            selection.anchor = event.modifierFlags.contains(.shift) ? previous ?? target : target
            tracking = true
            downPoint = point
            if let anchor = selection.anchor { selection.select(from: anchor, to: target) }
            window.makeFirstResponder(self)
            let position = target.view.convert(point, from: nil)
            if target.index < target.view.textStorage!.length,
               let manager = target.view.layoutManager, let container = target.view.textContainer {
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: target.index, length: 1), actualCharacterRange: nil)
                guard manager.boundingRect(forGlyphRange: glyphs, in: container).contains(position) else { return true }
                let link = target.view.textStorage!.attribute(.link, at: target.index, effectiveRange: nil)
                pressedLink = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            }
            return true
        case .leftMouseDragged:
            guard tracking, let anchor = selection.anchor, let target = selection.nearest(to: point) else { return false }
            dragging = dragging || hypot(point.x - downPoint.x, point.y - downPoint.y) > 3
            if dragging { selection.select(from: anchor, to: target) }
            return true
        case .leftMouseUp:
            guard tracking else { return false }
            tracking = false
            if !dragging, let pressedLink { NSWorkspace.shared.open(pressedLink) }
            pressedLink = nil
            dragging = false
            return true
        default: return false
        }
    }
}

struct CodexSelectionExclusion: NSViewRepresentable {
    @Environment(\.codexBookSelection) private var selection
    func makeNSView(context: Context) -> NSView { ExclusionView() }
    func updateNSView(_ view: NSView, context: Context) { selection?.exclusions.add(view) }
    private final class ExclusionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// Separate text views share one active selection, including its background color.
private final class CodexSelectionLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let view = textContainers.first?.textView as? CodexSelectableTextView,
              let selection = view.bookSelection,
              (view.window?.firstResponder === selection.surface
                || (view.window?.firstResponder as? CodexSelectableTextView)?.bookSelection === selection), charRange.length > 0,
              NSIntersectionRange(view.selectedRange(), charRange) == charRange else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.selectedTextBackgroundColor.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange,
                                      color: .selectedTextBackgroundColor)
    }
}

struct CodexPageKeys: NSViewRepresentable {
    static func approvalDecision(keyCode: UInt16, isRepeat: Bool, hasMarkedText: Bool) -> Bool? {
        guard !isRepeat, !hasMarkedText else { return nil }
        switch keyCode {
        case 36, 76: return true
        case 53: return false
        default: return nil
        }
    }

    let focus: CodexBookFocus
    let paneFocus: TabPaneFocus
    let approval: CodexRequest?
    let approve: (CodexRequest, Bool) -> Void
    let move: (Int) -> Void

    func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty else { return false }
        if [36, 76, 53].contains(event.keyCode) {
            guard paneFocus.contains(window), let approval,
                  (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
            if let allow = Self.approvalDecision(keyCode: event.keyCode, isRepeat: event.isARepeat, hasMarkedText: false) {
                approve(approval, allow)
            }
            return true
        }
        guard focus.isReading(in: window),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (123, _), (_, "h"):
            focus.activateReading()
            move(-1)
        case (124, _), (_, "l"):
            focus.activateReading()
            move(1)
        case (_, "/"):
            focus.activateInput()
        default:
            return false
        }
        return true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor else { return event }
            return coordinator?.handle?(event) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
        var handle: ((NSEvent) -> Bool)?
    }
    private final class EventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
