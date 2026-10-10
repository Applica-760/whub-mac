import AppKit
import Combine
import SwiftUI

final class RetainedPageActivity {
    let isActive = CurrentValueSubject<Bool, Never>(false)

    func setActive(_ active: Bool) {
        guard isActive.value != active else { return }
        isActive.send(active)
    }
}

extension EnvironmentValues {
    @Entry var isRetainedPageActive = true
    @Entry var retainedPageActivity: RetainedPageActivity? = nil
}

struct RetainedPageContainer<Page: Hashable, Content: View>: NSViewRepresentable {
    let selection: Page
    @ViewBuilder let content: (Page) -> Content
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.pages[selection] == nil {
            let activity = RetainedPageActivity()
            let page = NSHostingView(rootView: rootView(for: selection, activity: activity))
            page.sizingOptions = []
            page.frame = container.bounds
            page.autoresizingMask = [.width, .height]
            page.isHidden = true
            container.addSubview(page)
            coordinator.pages[selection] = HostedPage(view: page, activity: activity)
        }

        // Stop work before hiding; hidden hosting views can defer SwiftUI updates.
        for (id, page) in coordinator.pages where id != selection {
            page.activity.setActive(false)
        }
        for (id, hosted) in coordinator.pages {
            let page = hosted.view
            let isActive = id == selection
            if !isActive, !page.isHidden,
               let responder = container.window?.firstResponder as? NSView,
               responder.isDescendant(of: page) {
                container.window?.makeFirstResponder(nil)
            }
            page.isHidden = !isActive
            page.setAccessibilityHidden(!isActive)
            page.rootView = rootView(for: id, activity: hosted.activity)
            if isActive { hosted.activity.setActive(true) }
        }

        assert(coordinator.pages.values.filter { !$0.view.isHidden }.count == 1)
        assert(coordinator.pages.values.allSatisfy { $0.view.superview === container })
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        for page in coordinator.pages.values { page.activity.setActive(false) }
    }

    private func rootView(for page: Page, activity: RetainedPageActivity) -> AnyView {
        AnyView(content(page)
            .environment(\.retainedPageActivity, activity)
            .environment(\.isRetainedPageActive, page == selection)
            .environment(\.self, environment))
    }

    struct HostedPage {
        let view: NSHostingView<AnyView>
        let activity: RetainedPageActivity
    }

    final class Coordinator {
        var pages: [Page: HostedPage] = [:]
    }
}
