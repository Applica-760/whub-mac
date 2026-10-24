import AppKit
import Testing

@MainActor
final class TabTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
func sendTabTestKey(_ key: String, code: UInt16, to window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key,
        isARepeat: false, keyCode: code))
    NSApplication.shared.sendEvent(event)
}

@MainActor
func tabTestViews<T: NSView>(in view: NSView, of type: T.Type) -> [T] {
    let current = (view as? T).map { [$0] } ?? []
    return current + view.subviews.flatMap { tabTestViews(in: $0, of: type) }
}
