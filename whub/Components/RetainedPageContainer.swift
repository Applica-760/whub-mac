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
    var availablePages: [Page]? = nil
    @ViewBuilder let content: (Page) -> Content
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.update(container, selection: selection, availablePages: availablePages,
                                   isActive: environment.isRetainedPageActive, rootView: rootView)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        for page in coordinator.pages.values { page.activity.setActive(false) }
    }

    private func rootView(for page: Page, activity: RetainedPageActivity) -> AnyView {
        AnyView(content(page)
            .environment(\.retainedPageActivity, activity)
            .environment(\.isRetainedPageActive, environment.isRetainedPageActive && page == selection)
            .environment(\.self, environment))
    }

    struct HostedPage {
        let view: NSHostingView<AnyView>
        let activity: RetainedPageActivity
    }

    final class Coordinator {
        var pages: [Page: HostedPage] = [:]

        func update(_ container: NSView, selection: Page, availablePages: [Page]?, isActive: Bool,
                    rootView: (Page, RetainedPageActivity) -> AnyView) {
            if let availablePages {
                let available = Set(availablePages)
                for id in Array(pages.keys) where !available.contains(id) {
                    guard let page = pages.removeValue(forKey: id) else { continue }
                    page.activity.setActive(false)
                    if let responder = container.window?.firstResponder as? NSView,
                       responder.isDescendant(of: page.view) {
                        container.window?.makeFirstResponder(nil)
                    }
                    page.view.removeFromSuperview()
                }
            }
            if pages[selection] == nil {
                let activity = RetainedPageActivity()
                let page = NSHostingView(rootView: rootView(selection, activity))
                page.sizingOptions = []
                page.frame = container.bounds
                page.autoresizingMask = [.width, .height]
                page.isHidden = true
                container.addSubview(page)
                pages[selection] = HostedPage(view: page, activity: activity)
            }

            // Stop work before hiding; hidden hosting views can defer SwiftUI updates.
            for (id, page) in pages where id != selection || !isActive {
                page.activity.setActive(false)
            }
            for (id, hosted) in pages {
                let page = hosted.view
                let selected = id == selection
                if !selected, !page.isHidden,
                   let responder = container.window?.firstResponder as? NSView,
                   responder.isDescendant(of: page) {
                    container.window?.makeFirstResponder(nil)
                }
                page.isHidden = !selected
                page.setAccessibilityHidden(!selected)
                page.rootView = rootView(id, hosted.activity)
                if selected && isActive { hosted.activity.setActive(true) }
            }

            assert(pages.values.filter { !$0.view.isHidden }.count == 1)
            assert(pages.values.allSatisfy { $0.view.superview === container })
        }
    }
}
