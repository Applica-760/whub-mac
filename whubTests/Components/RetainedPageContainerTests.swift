// テスト一覧:
// - sessionViewsSurviveSwitchesAndClosedTabsAreRemoved(): [TAB-006] 共通部品のView・入力・カーソル位置の保持を検証する（部分対応）。要求IDのない非表示時のフォーカス解除・閉じたViewの除去も確認する。
// - hiddenFeatureDeactivatesItsRetainedSession(): 要求IDなし。Feature非表示時の非アクティブ化と、再表示時の同じViewの再利用・アクティブ化を検証する。

import AppKit
import Combine
import SwiftUI
import Testing
@testable import whub

@Suite(.serialized) @MainActor
struct RetainedPageContainerTests {
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
