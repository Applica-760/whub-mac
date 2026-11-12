// テスト一覧:
// - sessionViewsSurviveSwitchesAndClosedTabsAreRemoved(): [TAB-F-006]
// - hiddenFeatureDeactivatesItsRetainedSession(): 要求IDなし。Feature非表示時の非アクティブ化と、再表示時の同じViewの再利用・アクティブ化を検証する。

import AppKit
import Combine
import SwiftUI
import Testing
@testable import whub

@Suite(.serialized) @MainActor
struct RetainedPageContainerTests {
    // Window notifications must reach retained children without a SwiftUI update.
    @Test func windowVisibilityPropagatesAndKeepsSelection() throws {
        let window = VisibilityTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let activity = RetainedPageActivity()
        let observer = WindowVisibilityObserver.VisibilityView(activity: activity)
        window.contentView = observer
        let coordinator = RetainedPageContainer<Int, Text>.Coordinator()
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in AnyView(Text("Page \(id)")) }
        coordinator.update(observer, selection: 1, availablePages: nil, isActive: true,
                           parentActivity: activity, rootView: root)
        let first = try #require(coordinator.pages[1])
        let nested = RetainedPageActivity()
        nested.setParent(first.activity)
        nested.setActive(true)
        #expect(nested.isActive.value)
        window.reportsVisible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!first.activity.isActive.value && !nested.isActive.value)
        window.reportsVisible = true
        window.reportsMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        #expect(!nested.isActive.value)
        window.reportsMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        #expect(nested.isActive.value)
        coordinator.update(observer, selection: 2, availablePages: nil, isActive: true,
                           parentActivity: activity, rootView: root)
        activity.setActive(false)
        activity.setActive(true)
        #expect(!nested.isActive.value)
        #expect(coordinator.pages[2]?.activity.isActive.value == true)
        #expect(coordinator.pages[1]?.view === first.view)
        window.contentView = nil
        #expect(!activity.isActive.value)
    }

    @Test func windowActivityIsIndependentAndSuppressesDuplicateNotifications() {
        let first = RetainedPageActivity()
        let second = RetainedPageActivity()
        let child = RetainedPageActivity()
        first.setActive(true)
        second.setActive(true)
        child.setParent(first)
        child.setActive(true)
        var changes: [Bool] = []
        let subscription = child.isActive.sink { changes.append($0) }
        first.setActive(false)
        first.setActive(false)
        #expect(second.isActive.value)
        child.setParent(second)
        first.setActive(true)
        #expect(changes == [true, false, true])
        withExtendedLifetime(subscription) {}
    }

    @Test func sessionViewsSurviveSwitchesAndClosedTabsAreRemoved() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let container = try #require(window.contentView)
        let coordinator = RetainedPageContainer<Int, RetainedInputProbe>.Coordinator()
        var inputs: [Int: NSTextView] = [:]
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in
            AnyView(RetainedInputProbe { inputs[id] = $0 })
        }

        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        let first = try #require(coordinator.pages[1])
        first.view.layoutSubtreeIfNeeded()
        let input = try #require(inputs[1])
        input.string = "draft"
        input.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(window.makeFirstResponder(input))

        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)

        #expect(first.view.isHidden)
        #expect(!first.activity.isActive.value)
        #expect(window.firstResponder !== input)
        let second = try #require(coordinator.pages[2])
        #expect(second.activity.isActive.value)

        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)

        #expect(coordinator.pages[1]?.view === first.view)
        #expect(coordinator.pages[2]?.view === second.view)
        #expect(!first.view.isHidden)
        #expect(first.activity.isActive.value)
        #expect(!second.activity.isActive.value)
        first.view.layoutSubtreeIfNeeded()
        #expect(inputs[1] === input)
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))

        coordinator.update(container, selection: 1, availablePages: [1], isActive: true, rootView: root)

        #expect(coordinator.pages.count == 1)
        #expect(second.view.superview == nil)
        #expect(!second.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === first.view)
    }

    @Test func workspaceSectionsCycleAndRetainEachPage() throws {
        let sections: [FeaturePage] = [.editor, .browser, .overview]
        #expect(FeaturePage.allCases == sections)
        #expect(FeaturePage.editor.moved(by: -1) == .overview)
        #expect(FeaturePage.overview.moved(by: 1) == .editor)
        for (index, section) in sections.enumerated() {
            #expect(section.moved(by: 1) == sections[(index + 1) % sections.count])
            #expect(section.moved(by: 1).moved(by: -1) == section)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = RetainedPageContainer<FeaturePage, RetainedInputProbe>.Coordinator()
        var inputs: [FeaturePage: NSTextView] = [:]
        let root: (FeaturePage, RetainedPageActivity) -> AnyView = { section, _ in
            AnyView(RetainedInputProbe { inputs[section] = $0 })
        }
        for section in sections {
            coordinator.update(container, selection: section, availablePages: nil,
                               isActive: true, rootView: root)
            let page = try #require(coordinator.pages[section])
            page.view.layoutSubtreeIfNeeded()
            let input = try #require(inputs[section])
            input.string = section.label
        }
        let originalPages = coordinator.pages
        for section in sections.reversed() {
            coordinator.update(container, selection: section, availablePages: nil,
                               isActive: true, rootView: root)
            #expect(coordinator.pages[section]?.view === originalPages[section]?.view)
            #expect(inputs[section]?.string == section.label)
            #expect(coordinator.pages.values.filter { $0.activity.isActive.value }.count == 1)
            #expect(coordinator.pages[section]?.activity.isActive.value == true)
        }
    }

    @Test func hiddenFeatureDeactivatesItsRetainedSession() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = RetainedPageContainer<Int, Text>.Coordinator()
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in AnyView(Text("Session \(id)")) }

        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)
        let session = try #require(coordinator.pages[1])

        coordinator.update(container, selection: 1, availablePages: nil, isActive: false, rootView: root)

        #expect(!session.activity.isActive.value)

        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)

        #expect(session.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === session.view)
    }
}

private struct RetainedInputProbe: NSViewRepresentable {
    let created: (NSTextView) -> Void
    func makeNSView(context: Context) -> NSTextView {
        let input = NSTextView()
        created(input)
        return input
    }
    func updateNSView(_ view: NSTextView, context: Context) {}
}

private final class VisibilityTestWindow: NSWindow {
    var reportsVisible = true
    var reportsMiniaturized = false
    override var occlusionState: NSWindow.OcclusionState { reportsVisible ? .visible : [] }
    override var isMiniaturized: Bool { reportsMiniaturized }
}
