import AppKit
import SwiftUI

struct WindowVisibility: ViewModifier {
    @State private var activity = RetainedPageActivity()
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .environment(\.isRetainedPageActive, isVisible)
            .environment(\.retainedPageActivity, activity)
            .background(WindowVisibilityObserver(activity: activity))
            .onReceive(activity.isActive) { isVisible = $0 }
    }
}

struct WindowVisibilityObserver: NSViewRepresentable {
    let activity: RetainedPageActivity

    func makeNSView(context: Context) -> VisibilityView { VisibilityView(activity: activity) }
    func updateNSView(_ view: VisibilityView, context: Context) {}

    final class VisibilityView: NSView {
        let activity: RetainedPageActivity

        init(activity: RetainedPageActivity) {
            self.activity = activity
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification,
                             NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    center.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
                }
                center.addObserver(self, selector: #selector(stop), name: NSWindow.willCloseNotification, object: window)
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                    center.addObserver(self, selector: #selector(updateVisibility), name: name, object: NSApp)
                }
            }
            updateVisibility()
        }

        @objc private func updateVisibility() {
            activity.setActive(window.map {
                $0.occlusionState.contains(.visible) && !$0.isMiniaturized && !NSApp.isHidden
            } ?? false)
        }

        @objc private func stop() { activity.setActive(false) }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
