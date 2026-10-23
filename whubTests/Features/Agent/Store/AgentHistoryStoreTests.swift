import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct AgentHistoryStoreTests {
    @Test func historyStoreDeduplicatesPagesAndPreservesEntriesOnFailure() async {
        let backend = TestAgentSession()
        var fail = false
        backend.historyAction = { cursor in
            if fail { throw CodexAgentError(message: "failed") }
            return AgentHistoryPage(entries: [testHistoryEntry("one"), testHistoryEntry(cursor == nil ? "one" : "two")], nextCursor: cursor == nil ? "next" : nil)
        }
        let history = AgentHistoryStore(session: backend)
        await history.load()
        #expect(history.entries.map(\.id) == ["one"])
        await history.load(more: true)
        #expect(history.entries.map(\.id) == ["one", "two"] && history.nextCursor == nil)
        fail = true
        await history.load()
        #expect(history.entries.count == 2 && history.errorMessage == "failed" && !history.isLoading)
    }
}
