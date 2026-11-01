// テスト一覧:
// - numberKeysSwitchTerminalFocusAndRetainSessions(): [TAB-F-001] [TAB-F-003] [TAB-F-006]
// - commandWClosesSelectedTerminalTabAndFocusesReplacement(): [TAB-F-007] [TAB-F-010]
// - ownedStoreRetainsSessionsAndReadsBasePathForNewTabs(): Store保持、BasePath再取得、非表示・他ウィンドウでの操作抑止、作成不可のタブ画面から戻った後の作成を検証。

import AppKit
import Combine
import SwiftData
import SwiftTerm
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct TerminalViewTests {
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

    @Test func ownedStoreRetainsSessionsAndReadsBasePathForNewTabs() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let hosts = HostStore(context: database.mainContext)
        let local = try hosts.addLocal(name: "local", basePath: "/first")
        var directories: [String] = []
        var sessions: [TerminalSession] = []
        var creations = 0
        var action: ((NSWindow) -> Void)?
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
        let host = NSHostingView(rootView: TerminalOwnershipTestRoot(selection: selection, makeStore: makeStore,
                                                                    receiveAction: { action = $0 }))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        window.makeKey()
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions.count == 1 && window.firstResponder === sessions[0].terminal && action != nil
        }
        #expect(directories == ["/first"])
        let newTab = try #require(action)
        try hosts.editLocal(local, name: "local", basePath: "/second")
        newTab(window)
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
        newTab(otherWindow)
        #expect(sessions.count == 2)

        selection.showsTerminal = false
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return sessions[1].terminal.isHiddenOrHasHiddenAncestor
        }
        newTab(window)
        #expect(sessions.count == 2)
        selection.showsTerminal = true
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === sessions[1].terminal && !sessions[1].terminal.isHiddenOrHasHiddenAncestor
        }
        #expect(creations == 1)
        #expect(directories == ["/first", "/second"])
        let restoredAction = try #require(action)
        restoredAction(window)
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
    let receiveAction: (((NSWindow) -> Void)?) -> Void

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
        .background(TerminalActionProbe(receive: receiveAction))
    }
}

private struct TerminalActionProbe: View {
    @FocusedValue(\.createTab) private var action
    let receive: (((NSWindow) -> Void)?) -> Void

    var body: some View {
        Color.clear.onChange(of: action != nil, initial: true) { receive(action) }
    }
}

private final class TerminalInputProbe: LocalProcessTerminalView {
    var received = ""
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        received += String(decoding: data, as: UTF8.self)
    }
}
