import AppKit
import SwiftUI

final class TabPaneFocus {
    weak var view: NSView?

    func activate() {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return }
        view.window?.makeFirstResponder(view)
    }

    func contains(_ window: NSWindow) -> Bool {
        guard let view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
              let responder = window.firstResponder as? NSView else { return false }
        if responder === view { return true }
        let rect = view.convert(responder.bounds.intersection(responder.visibleRect), from: responder)
        return !rect.isEmpty && view.bounds.intersection(view.visibleRect).insetBy(dx: -1, dy: -1).contains(rect)
    }
}

struct TabPaneFocusView: NSViewRepresentable {
    let focus: TabPaneFocus

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = FocusView()
        focus.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak view] event in
            guard let view, let window = view.window,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil))
            else { return event }
            if !focus.contains(window) { window.makeFirstResponder(view) }
            return event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { focus.view = view }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var monitor: Any?
    }

    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
