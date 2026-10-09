//
//  whubTests.swift
//  whubTests
//
//  Created by 村上匠 on 2026/10/08.
//

import Combine
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexCompletionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func completionsBelongToSecondAndFourthTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<3 { store.add() }
        let ids = store.sessions.map(\.id)
        var published: Set<CodexStore.ID> = []
        let observation = store.$completedSessionIDs.sink { published = $0 }
        defer { observation.cancel() }

        store.sessions[1].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1]])
        store.sessions[3].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1], ids[3]])
        #expect(published == [ids[1], ids[3]])

        store.select(ids[1])
        #expect(store.completedSessionIDs == [ids[3]])
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
        store.sessions[3].onCompletionChange?(true)
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func completionSurvivesReorderingAndHiddenTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<3 { store.add() }
        let first = store.sessions[0]
        let fourth = store.sessions[3]
        store.select(first.id)
        fourth.onCompletionChange?(true)
        let visible = CodexTabBar.visibleRange(count: store.sessions.count, selectedIndex: 0)
        #expect(!visible.contains(3))
        #expect(store.completedSessionIDs == [fourth.id])

        store.move(fourth.id, before: first.id)
        #expect(store.sessions[0].id == fourth.id)
        #expect(store.completedSessionIDs == [fourth.id])
        store.select(fourth.id)
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func resetAndRestartClearOnlyTheirOwnCompletion() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let first = store.sessions[0]
        let second = store.sessions[1]
        first.onCompletionChange?(true)
        second.onCompletionChange?(true)
        first.onCompletionChange?(false)
        #expect(store.completedSessionIDs == [second.id])
        second.reset()
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func removedTabsCannotRestoreTheirBadge() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let removed = store.sessions[1]
        removed.onCompletionChange?(true)
        store.remove(removed.id)
        #expect(store.completedSessionIDs.isEmpty)
        removed.onCompletionChange?(true)
        #expect(store.completedSessionIDs.isEmpty)
    }
}
