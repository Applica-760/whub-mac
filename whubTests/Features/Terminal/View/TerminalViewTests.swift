// テスト一覧:
// - commandWClosesSelectedTerminalTabAndFocusesReplacement(): [TAB-F-007] [TAB-F-010]

import AppKit
import SwiftData
import SwiftTerm
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct TerminalViewTests {
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
        let host = NSHostingView(rootView: TerminalView().environmentObject(store))
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
}

private final class TerminalInputProbe: LocalProcessTerminalView {
    var received = ""
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        received += String(decoding: data, as: UTF8.self)
    }
}
