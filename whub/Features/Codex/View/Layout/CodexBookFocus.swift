import AppKit
import SwiftUI

@MainActor
final class CodexBookFocus {
    weak var readingView: CodexBookTextSurface?
    weak var inputView: NSView?

    func isReading(in window: NSWindow) -> Bool {
        readingView?.isReading(in: window) == true
    }

    func activateReading() {
        readingView?.activateReading()
    }

    func activateInput() {
        guard let inputView, !inputView.isHiddenOrHasHiddenAncestor else { return }
        inputView.window?.makeFirstResponder(inputView)
    }
}

struct CodexPageKeys: NSViewRepresentable {
    let focus: CodexBookFocus
    let move: (Int) -> Void

    func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty else { return false }
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

struct CodexApprovalKeys: NSViewRepresentable {
    static func approvalDecision(keyCode: UInt16, isRepeat: Bool, hasMarkedText: Bool) -> Bool? {
        guard !isRepeat, !hasMarkedText else { return nil }
        switch keyCode {
        case 36, 76: return true
        case 53: return false
        default: return nil
        }
    }

    let approve: (Bool) -> Void

    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.window === window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty,
              [36, 76, 53].contains(event.keyCode),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        if let allow = Self.approvalDecision(keyCode: event.keyCode, isRepeat: event.isARepeat, hasMarkedText: false) {
            approve(allow)
        }
        return true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow,
                  !view.isHiddenOrHasHiddenAncestor else { return event }
            return coordinator?.handle?(event, window) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
        var handle: ((NSEvent, NSWindow) -> Bool)?
    }
    final class EventView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeKey()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
