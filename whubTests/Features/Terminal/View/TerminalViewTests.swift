// テスト一覧:
// - numberKeysSwitchTerminalFocusAndRetainSessions(): [TAB-F-001] [TAB-F-003] [TAB-F-006]
// - commandWClosesSelectedTerminalTabAndFocusesReplacement(): [TAB-F-007] [TAB-F-010]
// - createTargetsOnlyFocusedPaneWithTerminalAndAgentBookVisible(): 同時表示したペインの作成先と確認中の抑止。
// - ownedStoreRetainsSessionsAndReadsBasePathForNewTabs(): Store保持、BasePath再取得、非表示・他ウィンドウでの操作抑止、作成不可のタブ画面から戻った後の作成を検証。

import AppKit
import Combine
import MetalKit
import SwiftData
import SwiftTerm
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

@Suite @MainActor
struct TerminalViewTests {
    @Test func windowActivityPausesRenderingWithoutReplacingTerminal() async throws {
        let terminal = TerminalInputProbe(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        try terminal.setUseMetal(true)
        let activity = RetainedPageActivity()
        activity.setActive(true)
        let host = NSHostingView(rootView: LocalTerminalView(terminal: terminal)
            .environment(\.retainedPageActivity, activity))
        let window = TabTestWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return terminal.window === window
        }
        let renderer = try #require(terminal.subviews.compactMap { $0 as? MTKView }.first)
        #expect(renderer.enableSetNeedsDisplay)
        #expect(renderer.isPaused)
        activity.setActive(false)
        #expect(!renderer.enableSetNeedsDisplay)
        terminal.feed(text: "output received while hidden")
        #expect(terminal.window === window)
        activity.setActive(true)
        #expect(renderer.enableSetNeedsDisplay)
        #expect(terminal.window === window)
        #expect(renderer.isPaused)
    }

    @Test func visibilityResumeKeepsFocusInOtherPane() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = TerminalStore(context: database.mainContext, makeSession: { _ in
            TerminalSession(terminal: TerminalInputProbe(frame: .zero))
        })
        let other = TerminalInputProbe(frame: .zero)
        func root(_ active: Bool) -> AnyView {
            AnyView(HStack {
                TerminalView(store: store).environment(\.isRetainedPageActive, active)
                LocalTerminalView(terminal: other)
            })
        }
        let host = NSHostingView(rootView: root(true))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === store.selectedSession.terminal
        }
        host.rootView = root(false)
        host.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(other))
        host.rootView = root(true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === other)
    }

    @Test func numberKeysSwitchTerminalFocusAndRetainSessions() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var creations = 0
        let store = TerminalStore(context: database.mainContext, makeSession: { _ in
            creations += 1
            return TerminalSession(terminal: TerminalInputProbe(frame: .zero))
        })
        for _ in 1..<9 { store.add() }
        let sessions = store.sessions
        sessions[0].terminal.feed(text: "retained output")
        let host = NSHostingView(rootView: TerminalView(store: store))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === sessions[8].terminal
        }

        for (index, keyCode) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            try sendTabTestKey(String(index + 1), code: UInt16(keyCode), to: window)
            try await waitForEditorTest {
                host.layoutSubtreeIfNeeded()
                return store.selectedSession === sessions[index] && window.firstResponder === sessions[index].terminal
            }
            let input = try #require(window.firstResponder as? TerminalInputProbe)
            input.insertText(String(index), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(input.received == String(index))
        }
        try sendTabTestKey("1", code: 18, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === sessions[0].terminal
        }
        #expect((sessions[0].terminal as? TerminalInputProbe)?.received == "0")
        #expect(String(decoding: sessions[0].terminal.getTerminal().getBufferAsData(), as: UTF8.self).contains("retained output"))
        #expect(creations == 9)
        #expect(zip(store.sessions, sessions).allSatisfy { $0 === $1 })
        store.move(sessions[8].id, before: sessions[0].id)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try sendTabTestKey("1", code: 18, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return store.selectedSession === sessions[8] && window.firstResponder === sessions[8].terminal
        }
        #expect((sessions[8].terminal as? TerminalInputProbe)?.received == "8")
    }

    @Test(arguments: [1, 2])
    func commandWClosesSelectedTerminalTabAndFocusesReplacement(tabCount: Int) async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var created: [TerminalInputProbe] = []
        let store = TerminalStore(context: database.mainContext, makeSession: { _ in
            let terminal = TerminalInputProbe(frame: .zero)
            created.append(terminal)
            return TerminalSession(terminal: terminal)
        })
        defer { store.sessions.forEach { $0.terminal.terminate() } }
        let first = store.selectedSession
        let firstInput = try #require(first.terminal as? TerminalInputProbe)
        firstInput.insertText("draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        if tabCount == 2 { store.add() }
        let closing = store.selectedSession
        let host = NSHostingView(rootView: TerminalView(store: store))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === closing.terminal
        }

        try sendTabTestKey("w", code: 13, to: window)

        try #require(store.selectedSessionID != closing.id)
        #expect(store.sessions.count == 1)
        #expect(!store.sessions.contains { $0 === closing })
        let selected = store.selectedSession
        let input = try #require(selected.terminal as? TerminalInputProbe)
        if tabCount == 1 {
            #expect(created.count == 2)
            #expect(input !== closing.terminal && input.received.isEmpty)
        } else {
            #expect(created.count == 2)
            #expect(selected === first)
            #expect(input.received == "draft")
        }
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === input && closing.terminal.window == nil
        }
        (window.firstResponder as? NSTextInputClient)?.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.received == (tabCount == 1 ? "x" : "draftx"))
        store.remove(closing.id)
        #expect(store.sessions.count == 1 && store.selectedSessionID == selected.id)
    }

    @Test func createTargetsOnlyFocusedPaneWithTerminalAndAgentBookVisible() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let terminal = TerminalStore(context: database.mainContext, makeSession: { _ in
            TerminalSession(terminal: TerminalInputProbe(frame: .zero))
        })
        let book = AgentBookStore(context: database.mainContext,
            runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { book.disconnect() }
        let connections = RemoteConnectionStore()
        let host = NSHostingView(rootView: HStack {
            TerminalView(store: terminal)
            AgentBookView(store: book)
        }
            .environmentObject(FilesStore())
            .environmentObject(connections)
            .environmentObject(RemoteServerStore(connections: connections)))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 750),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return terminal.selectedSession.terminal.window === window && book.selectedTab.store.isConnected
        }
        #expect(window.makeFirstResponder(terminal.selectedSession.terminal))
        CreateTab.perform(in: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return terminal.sessions.count == 2 && window.firstResponder === terminal.selectedSession.terminal
        }
        #expect(book.tabs.count == 1)

        let input = try #require(tabTestViews(in: host, of: NSTextView.self).first {
            $0.isEditable && !$0.isHiddenOrHasHiddenAncestor
        })
        #expect(window.makeFirstResponder(input))
        CreateTab.perform(in: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return book.tabs.count == 2 && book.selectedTab.store.isConnected
                && window.firstResponder is NSTextView && window.firstResponder !== input
        }
        #expect(terminal.sessions.count == 2)

        try sendTabTestKey("w", code: 13, to: window)
        try await waitForEditorTest { window.attachedSheet != nil }
        CreateTab.perform(in: window)
        #expect(book.tabs.count == 2 && terminal.sessions.count == 2)
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        let cancel = try #require(tabTestViews(in: content, of: NSButton.self)
            .first { $0.title == "キャンセル" })
        cancel.performClick(nil)
        try await waitForEditorTest { window.attachedSheet == nil }

        #expect(window.makeFirstResponder(terminal.selectedSession.terminal))
        CreateTab.perform(in: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return terminal.sessions.count == 3 && window.firstResponder === terminal.selectedSession.terminal
        }
        #expect(book.tabs.count == 2)
    }

    @Test func ownedStoreRetainsSessionsAndReadsBasePathForNewTabs() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let hosts = HostStore(context: database.mainContext)
        let local = try hosts.addLocal(name: "local", basePath: "/first")
        var directories: [String] = []
        var sessions: [TerminalSession] = []
        var creations = 0
        let selection = TerminalPageSelection()
        let makeStore = {
            creations += 1
            return TerminalStore(context: database.mainContext, makeSession: { directory in
                directories.append(directory)
                let session = TerminalSession(terminal: TerminalInputProbe(frame: .zero))
                sessions.append(session)
                return session
            })
        }
        let host = NSHostingView(rootView: TerminalOwnershipTestRoot(selection: selection, makeStore: makeStore))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        window.makeKey()
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions.count == 1 && window.firstResponder === sessions[0].terminal
        }
        #expect(directories == ["/first"])
        try hosts.editLocal(local, name: "local", basePath: "/second")
        CreateTab.perform(in: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions.count == 2 && window.firstResponder === sessions[1].terminal
        }
        #expect(directories == ["/first", "/second"])

        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let otherWindow = TabTestWindow(contentRect: other.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.contentView = nil; otherWindow.close() }
        otherWindow.contentView = other
        #expect(otherWindow.makeFirstResponder(other))
        CreateTab.perform(in: otherWindow)
        #expect(sessions.count == 2)

        selection.showsTerminal = false
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions[1].terminal.isHiddenOrHasHiddenAncestor
        }
        CreateTab.perform(in: window)
        #expect(sessions.count == 2)
        selection.showsTerminal = true
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === sessions[1].terminal && !sessions[1].terminal.isHiddenOrHasHiddenAncestor
        }
        #expect(creations == 1)
        #expect(directories == ["/first", "/second"])
        CreateTab.perform(in: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions.count == 3 && window.firstResponder === sessions[2].terminal
        }
        #expect(directories == ["/first", "/second", "/second"])
    }
}

@MainActor private final class TerminalPageSelection: ObservableObject {
    @Published var showsTerminal = true
}

private struct TerminalOwnershipTestRoot: View {
    @ObservedObject var selection: TerminalPageSelection
    let makeStore: () -> TerminalStore

    var body: some View {
        RetainedPageContainer(selection: selection.showsTerminal) { terminal in
            if terminal { TerminalView(store: makeStore()) }
            else {
                TabBarContainer(ids: [0], selection: 0, select: { _ in }, close: { _ in },
                                canClose: { _ in false }, move: { _, _ in },
                                isShortcutTarget: { _ in false }) { _, _, _ in
                    Text("Other page")
                }
            }
        }
    }
}

private final class TerminalInputProbe: LocalProcessTerminalView {
    var received = ""
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        received += String(decoding: data, as: UTF8.self)
    }
}
