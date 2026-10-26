// テスト一覧:
// - notificationsFollowTabsAcrossReorderingAndRemoval(): 並替え・削除後も通知をタブに対応付ける。
// - newConversationReplacesOnlyItsOwnStateAndLastTabRemains(): [TAB-F-011]
// - successfulResumeReplacesSourceInPlaceAndReusesExistingConversation(): 履歴再開のタブ置換と既存会話の再利用。
// - failedOrCancelledResumeDoesNotReplaceSource(): 履歴再開の失敗・取消時に元タブを保持する。
// - busyTabCannotResumeOrResetAndKindChangePreservesDraft(): 処理中の再開・リセット拒否と種類変更時の下書き保持。

import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

@Suite @MainActor
struct AgentBookStoreTests {
    @Test func notificationsFollowTabsAcrossReorderingAndRemoval() async throws {
        let context = try container()
        var backends: [TestAgentSession] = []
        var sounds: [String] = []
        let book = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in
            let session = TestAgentSession(); backends.append(session); return session
        }), notify: { sounds.append($0) })
        defer { book.disconnect() }
        for _ in 0..<6 { book.add() }
        let ids = book.tabs.map(\.id)
        for tab in book.tabs { await tab.store.connect(directory: "/project") }
        for index in [1, 3] {
            await book.tabs[index].store.connect(directory: "/project")
            await book.tabs[index].store.send([.text("work")])
            backends[index].emit(.completed)
        }
        #expect(await testEventually { book.completedTabIDs == [ids[1], ids[3]] })
        #expect(sounds == ["Glass", "Glass"])
        book.move(ids[3], before: ids[0])
        #expect(book.completedTabIDs == [ids[1], ids[3]])
        let visible = AgentBookTabButton.visibleRange(count: book.tabs.count, selectedIndex: 6)
        #expect(visible.count == 5 && visible.contains(6))
        book.select(ids[1])
        #expect(book.completedTabIDs == [ids[3]])
        book.remove(ids[3])
        backends[3].emit(.completed)
        #expect(!book.completedTabIDs.contains(ids[3]) && backends[3].isClosed)
    }

    @Test func newConversationReplacesOnlyItsOwnStateAndLastTabRemains() async throws {
        let context = try container()
        var backends: [TestAgentSession] = []
        let book = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in
            let session = TestAgentSession(); backends.append(session); return session
        }), notify: { _ in })
        defer { book.disconnect() }
        let first = book.selectedTab
        await first.store.connect(directory: "/project")
        first.store.draft = [.text("draft")]
        book.add()
        let second = book.selectedTab
        second.store.draft = [.text("keep")]
        #expect(book.newConversation(in: first.id))
        #expect(backends[0].isClosed && book.tabs[0].id != first.id)
        #expect(book.tabs[0].store.draft.isEmpty && second.store.draft == [.text("keep")])
        book.remove(second.id)
        let remaining = book.selectedTabID
        book.remove(remaining)
        #expect(book.tabs.count == 1 && book.selectedTabID != remaining)
    }

    @Test func successfulResumeReplacesSourceInPlaceAndReusesExistingConversation() async throws {
        let context = try container()
        let book = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { book.disconnect() }
        let source = book.selectedTab
        source.store.draft = [.text("discard after success")]
        let entry = testHistoryEntry()
        #expect(await book.resume(entry, replacing: source.id))
        #expect(book.tabs.count == 1 && source.store.isClosed)
        let resumed = book.selectedTab
        #expect(resumed.store.conversationID == entry.id && resumed.store.exchanges.count == 1)
        book.add()
        let empty = book.selectedTabID
        #expect(await book.resume(entry, replacing: empty))
        #expect(book.tabs.count == 1 && book.selectedTabID == resumed.id)
    }

    @Test func failedOrCancelledResumeDoesNotReplaceSource() async throws {
        let context = try container()
        var reply: CheckedContinuation<AgentHistorySnapshot, Error>?
        let entry = testHistoryEntry()
        let failedBook = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in
            let session = TestAgentSession()
            session.resumeAction = { _ in throw CodexAgentError(message: "failed") }
            return session
        }), notify: { _ in })
        defer { failedBook.disconnect() }
        let failedSource = failedBook.selectedTab
        failedSource.store.draft = [.text("keep")]
        #expect(await failedBook.resume(entry, replacing: failedSource.id) == false)
        #expect(failedBook.selectedTabID == failedSource.id && failedSource.store.draft == [.text("keep")])
        let pendingBook = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in
            let session = TestAgentSession()
            session.resumeAction = { _ in try await withCheckedThrowingContinuation { reply = $0 } }
            return session
        }), notify: { _ in })
        defer { pendingBook.disconnect() }
        let original = pendingBook.selectedTabID
        let loading = Task { await pendingBook.resume(entry, replacing: original) }
        #expect(await testEventually { reply != nil })
        pendingBook.remove(original)
        reply?.resume(returning: AgentHistorySnapshot(entry: entry, exchanges: [], selectedModelOption: nil))
        #expect(await loading.value == false)
        #expect(pendingBook.tabs.count == 1 && pendingBook.selectedTabID != original)
    }

    @Test func busyTabCannotResumeOrResetAndKindChangePreservesDraft() async throws {
        let context = try container()
        let backend = TestAgentSession()
        let book = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in backend }), notify: { _ in })
        defer { book.disconnect() }
        let source = book.selectedTab
        source.store.draft = [.text("keep")]
        await source.store.connect(directory: "/project")
        await source.store.send([.text("running")])
        #expect(await book.resume(testHistoryEntry(), replacing: source.id) == false)
        #expect(!book.newConversation(in: source.id))
        #expect(!book.changeKind(.claudeCode, in: source.id))
        let fresh = AgentBookStore(context: context.mainContext, runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { fresh.disconnect() }
        fresh.selectedTab.store.draft = [.text("draft")]
        #expect(fresh.changeKind(.claudeCode, in: fresh.selectedTabID))
        #expect(fresh.selectedTab.store.draft == [.text("draft")])
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
