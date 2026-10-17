import AppKit
import Combine

@MainActor
struct AgentBookTab: Identifiable {
    nonisolated let id: AgentStore.ID
    let store: AgentStore
    let skillStore: AgentSkillStore
    let historyStore: AgentHistoryStore

    init(session: any AgentSession) {
        let store = AgentStore(session: session)
        id = store.id
        self.store = store
        skillStore = AgentSkillStore(session: session)
        historyStore = AgentHistoryStore(session: session)
    }
}

@MainActor
final class AgentBookStore: ObservableObject {
    @Published private(set) var tabs: [AgentBookTab]
    @Published private(set) var selectedTabID: AgentBookTab.ID
    @Published private(set) var completedTabIDs: Set<AgentBookTab.ID> = []
    @Published private(set) var notificationDates: [AgentBookTab.ID: Date] = [:]
    @Published private(set) var isResuming = false
    @Published private(set) var resumeError: String?

    private let makeSession: (AgentKind) -> any AgentSession
    private let notify: (String) -> Void
    private var observations: [AgentBookTab.ID: AnyCancellable] = [:]
    private var pendingResume: AgentBookTab?
    private var pendingResumeSourceID: AgentBookTab.ID?

    init(kind: AgentKind = .codex,
         makeSession: @escaping (AgentKind) -> any AgentSession,
         notify: @escaping (String) -> Void = { NSSound(named: $0)?.play() }) {
        self.makeSession = makeSession
        self.notify = notify
        let tab = AgentBookTab(session: makeSession(kind))
        tabs = [tab]
        selectedTabID = tab.id
        observe(tab)
    }

    var selectedTab: AgentBookTab {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }

    func add() {
        let tab = AgentBookTab(session: makeSession(selectedTab.store.agentKind))
        tabs.append(tab)
        observe(tab)
        select(tab.id)
    }

    func select(_ id: AgentBookTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        completedTabIDs.remove(id)
    }

    func move(_ id: AgentBookTab.ID, before target: AgentBookTab.ID?) {
        guard let reordered = reorderedTabs(tabs, moving: id, before: target, identifiedBy: \.id) else { return }
        tabs = reordered
    }

    func remove(_ id: AgentBookTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let kind = tabs[index].store.agentKind
        close(tabs[index])
        if tabs.count == 1 {
            let replacement = AgentBookTab(session: makeSession(kind))
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
    func newConversation(in id: AgentBookTab.ID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              canReplace(tabs[index]) else { return false }
        let replacement = AgentBookTab(session: makeSession(tabs[index].store.agentKind))
        close(tabs[index])
        tabs[index] = replacement
        observe(replacement)
        if selectedTabID == id { select(replacement.id) }
        return true
    }

    @discardableResult
    func resume(_ entry: AgentHistoryEntry, replacing sourceID: AgentBookTab.ID) async -> Bool {
        guard !isResuming else { return false }
        resumeError = nil
        guard let source = tabs.first(where: { $0.id == sourceID }) else { return false }
        guard canReplace(source) else {
            resumeError = "作業や送信が終わってから会話を再開してください。"
            return false
        }
        if let existing = resumedTab(for: entry, kind: source.store.agentKind) {
            return open(existing, replacing: sourceID)
        }

        let tab = AgentBookTab(session: makeSession(source.store.agentKind))
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
            tab.store.disconnect()
            return false
        }
        pendingResume = nil
        pendingResumeSourceID = nil
        isResuming = false
        return open(tab, replacing: sourceID)
    }

    func disconnect() {
        cancelPendingResume()
        observations.removeAll()
        for tab in tabs { tab.store.disconnect() }
    }

    private func canReplace(_ tab: AgentBookTab) -> Bool {
        let store = tab.store
        return !store.isConnecting && !store.isBusy && !store.isSendingAdditionalInput
            && !store.isResuming && !store.isChangingModel && store.respondingRequestIDs.isEmpty
    }

    private func resumedTab(for entry: AgentHistoryEntry, kind: AgentKind) -> AgentBookTab? {
        // shortcut: 通常送信で始まった会話のID通知をAgentStoreへ追加する際、重複判定の対象を広げる。
        tabs.first { $0.store.agentKind == kind && $0.store.historyEntry?.id == entry.id }
    }

    private func open(_ tab: AgentBookTab, replacing sourceID: AgentBookTab.ID) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == sourceID }),
              canReplace(tabs[sourceIndex]) else {
            if !tabs.contains(where: { $0.id == tab.id }) { tab.store.disconnect() }
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

    private func close(_ tab: AgentBookTab) {
        if pendingResumeSourceID == tab.id { cancelPendingResume() }
        observations.removeValue(forKey: tab.id)
        completedTabIDs.remove(tab.id)
        notificationDates.removeValue(forKey: tab.id)
        tab.store.disconnect()
    }

    private func cancelPendingResume() {
        pendingResume?.store.disconnect()
        pendingResume = nil
        pendingResumeSourceID = nil
        isResuming = false
    }

    private func observe(_ tab: AgentBookTab) {
        let id = tab.id
        var runningIDs: Set<AgentExchange.ID> = []
        var approvalIDs: Set<String> = []
        observations[id] = tab.store.$exchanges.sink { [weak self] exchanges in
            guard let self, self.tabs.contains(where: { $0.id == id }) else { return }
            let running = exchanges.filter { $0.status == .running }
            let nextRunningIDs = Set(running.map(\.id))
            let nextApprovalIDs = Set(running.flatMap(\.pendingRequests).filter(\.isApproval).map(\.id))
            if !nextRunningIDs.subtracting(runningIDs).isEmpty { self.completedTabIDs.remove(id) }
            if exchanges.contains(where: { runningIDs.contains($0.id) && $0.status == .completed }) {
                self.completedTabIDs.insert(id)
                self.notificationDates[id] = Date()
                self.notify("Glass")
            }
            for _ in nextApprovalIDs.subtracting(approvalIDs) {
                self.notificationDates[id] = Date()
                self.notify("Blow")
            }
            runningIDs = nextRunningIDs
            approvalIDs = nextApprovalIDs
        }
    }
}
