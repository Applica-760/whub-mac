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
    var bottomInset: CGFloat = 64
    private var anchor: (view: CodexSelectableTextView, index: Int)?
    private var pressedLink: URL?
    private var downPoint = NSPoint.zero
    private var dragging = false
    private var tracking = false

    var orderedTexts: [CodexSelectableTextView] {
        texts.allObjects.filter { $0.window === surface?.window && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.readingOrder.lexicographicallyPrecedes($1.readingOrder) }
    }

    func clear() {
        for view in texts.allObjects { view.highlight(NSRange(location: 0, length: 0)) }
        anchor = nil
        pressedLink = nil
        dragging = false
        tracking = false
    }

    func remove(_ view: CodexSelectableTextView) {
        if anchor?.view === view { clear() }
        texts.remove(view)
    }

    private func nearest(to point: NSPoint) -> (view: CodexSelectableTextView, index: Int)? {
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

    func handle(_ event: NSEvent) -> Bool {
        guard let surface, let window = surface.window, window.isKeyWindow,
              event.window === window, window.attachedSheet == nil, !surface.isHiddenOrHasHiddenAncestor else { return false }
        let point = event.locationInWindow
        switch event.type {
        case .leftMouseDown:
            let local = surface.convert(point, from: nil)
            guard surface.bounds.contains(local), local.y < surface.bounds.height - bottomInset,
                  !exclusions.allObjects.contains(where: { $0.convert($0.bounds, to: nil).contains(point) }),
                  let target = nearest(to: point) else { return false }
            if event.clickCount > 1 { clear(); return false }
            let previous = anchor
            clear()
            anchor = event.modifierFlags.contains(.shift) ? previous ?? target : target
            tracking = true
            downPoint = point
            if let anchor { select(from: anchor, to: target) }
            window.makeFirstResponder(target.view)
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
            guard tracking, let anchor, let target = nearest(to: point) else { return false }
            dragging = dragging || hypot(point.x - downPoint.x, point.y - downPoint.y) > 3
            if dragging { select(from: anchor, to: target) }
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

struct CodexSelectionSurface: NSViewRepresentable {
    let selection: CodexBookSelection
    let bottomInset: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = SurfaceView()
        selection.surface = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak selection] event in
            selection?.handle(event) == true ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { selection.surface = view; selection.bottomInset = bottomInset }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator { var monitor: Any? }
    private final class SurfaceView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
              let focused = view.window?.firstResponder as? CodexSelectableTextView,
              focused.bookSelection === selection, charRange.length > 0,
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
