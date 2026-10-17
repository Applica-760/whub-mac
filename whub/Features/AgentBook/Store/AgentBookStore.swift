import AppKit
import Combine
import SwiftData
import WhubCore

@MainActor
final class AgentBookStore: ObservableObject {
    @Published private(set) var tabs: [AgentBookTabStore]
    @Published private(set) var selectedTabID: AgentBookTabStore.ID
    @Published private(set) var isResuming = false
    @Published private(set) var resumeError: String?

    private let context: ModelContext
    private let makeSession: (AgentKind) -> any AgentSession
    private let notify: (String) -> Void
    private var observations: [AgentBookTabStore.ID: AnyCancellable] = [:]
    private var pendingResume: AgentBookTabStore?
    private var pendingResumeSourceID: AgentBookTabStore.ID?

    init(context: ModelContext, kind: AgentKind = .codex,
         makeSession: @escaping (AgentKind) -> any AgentSession,
         notify: @escaping (String) -> Void = { NSSound(named: $0)?.play() }) {
        self.context = context
        self.makeSession = makeSession
        self.notify = notify
        let tab = AgentBookTabStore(session: makeSession(kind))
        tabs = [tab]
        selectedTabID = tab.id
        observe(tab)
    }

    var selectedTab: AgentBookTabStore {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    var completedTabIDs: Set<AgentBookTabStore.ID> {
        Set(tabs.filter(\.hasCompleted).map(\.id))
    }

    var notificationDates: [AgentBookTabStore.ID: Date] {
        Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.notificationDate.map { (tab.id, $0) }
        })
    }

    func connect(_ id: AgentBookTabStore.ID) async {
        guard let tab = tabs.first(where: { $0.id == id }),
              !tab.store.isClosed, !tab.store.isConnected else { return }
        let directory = tab.store.historyEntry?.directory
            ?? (try? HostStore(context: context).fetchHosts().first { $0 is LocalHost }?.basePath)
            ?? NSHomeDirectory()
        await tab.store.connect(directory: directory)
    }

    func add() {
        let tab = AgentBookTabStore(session: makeSession(selectedTab.store.agentKind))
        tabs.append(tab)
        observe(tab)
        select(tab.id)
    }

    func select(_ id: AgentBookTabStore.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTabID = id
        tab.markRead()
    }

    func move(_ id: AgentBookTabStore.ID, before target: AgentBookTabStore.ID?) {
        guard let reordered = reorderedTabs(tabs, moving: id, before: target, identifiedBy: \.id) else { return }
        tabs = reordered
    }

    func remove(_ id: AgentBookTabStore.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let kind = tabs[index].store.agentKind
        close(tabs[index])
        if tabs.count == 1 {
            let replacement = AgentBookTabStore(session: makeSession(kind))
            tabs[index] = replacement
            observe(replacement)
        } else {
            tabs.remove(at: index)
        }
        if selectedTabID == id { select(tabs[min(index, tabs.count - 1)].id) }
        assert(!tabs.isEmpty && tabs.contains { $0.id == selectedTabID })
    }

    // 確認ダイアログはViewが表示してから呼ぶ。
    @discardableResult
    func newConversation(in id: AgentBookTabStore.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].canReplace else { return false }
        let replacement = AgentBookTabStore(session: makeSession(tabs[index].store.agentKind))
        close(tabs[index])
        tabs[index] = replacement
        observe(replacement)
        if selectedTabID == id { select(replacement.id) }
        return true
    }

    @discardableResult
    func resume(_ entry: AgentHistoryEntry, replacing sourceID: AgentBookTabStore.ID) async -> Bool {
        guard !isResuming else { return false }
        resumeError = nil
        guard let source = tabs.first(where: { $0.id == sourceID }) else { return false }
        guard source.canReplace else {
            resumeError = "作業や送信が終わってから会話を再開してください。"
            return false
        }
        if let existing = openTab(for: entry, kind: source.store.agentKind) {
            return open(existing, replacing: sourceID)
        }

        let tab = AgentBookTabStore(session: makeSession(source.store.agentKind))
        pendingResume = tab
        pendingResumeSourceID = sourceID
        isResuming = true
        defer {
            if pendingResume?.id == tab.id {
                pendingResume = nil
                pendingResumeSourceID = nil
                isResuming = false
            }
        }

        let succeeded = await tab.store.resume(entry)
        guard pendingResume?.id == tab.id else { return false }
        guard !Task.isCancelled, succeeded else {
            resumeError = tab.store.errorMessage ?? "会話を再開できませんでした。"
            tab.disconnect()
            return false
        }
        pendingResume = nil
        pendingResumeSourceID = nil
        isResuming = false
        let target = openTab(for: entry, kind: source.store.agentKind) ?? tab
        if target.id != tab.id { tab.disconnect() }
        return open(target, replacing: sourceID)
    }

    func disconnect() {
        cancelPendingResume()
        observations.removeAll()
        for tab in tabs { tab.disconnect() }
    }

    private func openTab(for entry: AgentHistoryEntry, kind: AgentKind) -> AgentBookTabStore? {
        tabs.first { $0.store.agentKind == kind && $0.store.conversationID == entry.id }
    }

    private func open(_ tab: AgentBookTabStore, replacing sourceID: AgentBookTabStore.ID) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }),
              tabs[sourceIndex].canReplace else {
            if !tabs.contains(where: { $0.id == tab.id }) { tab.disconnect() }
            resumeError = "作業や送信が終わってから会話を再開してください。"
            return false
        }
        if tab.id != sourceID {
            let alreadyOpen = tabs.contains { $0.id == tab.id }
            close(tabs[sourceIndex])
            var updated = tabs
            updated[sourceIndex] = tab
            tabs = updated.enumerated().filter { $0.offset == sourceIndex || $0.element.id != tab.id }.map(\.element)
            if !alreadyOpen { observe(tab) }
        }
        select(tab.id)
        return true
    }

    private func close(_ tab: AgentBookTabStore) {
        if pendingResumeSourceID == tab.id { cancelPendingResume() }
        observations.removeValue(forKey: tab.id)
        tab.disconnect()
    }

    private func cancelPendingResume() {
        pendingResume?.disconnect()
        pendingResume = nil
        pendingResumeSourceID = nil
        isResuming = false
    }

    private func observe(_ tab: AgentBookTabStore) {
        let id = tab.id
        observations[id] = tab.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        tab.onNotification = { [weak self] sound in
            guard let self, self.tabs.contains(where: { $0.id == id }) else { return }
            self.notify(sound)
        }
    }
}
