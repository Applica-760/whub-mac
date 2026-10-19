import AppKit
import Combine
import SwiftData
import WhubAgent
import WhubCore

@MainActor
final class AgentBookStore: ObservableObject {
    @Published private(set) var tabs: [AgentBookTabStore]
    @Published private(set) var selectedTabID: AgentBookTabStore.ID
    @Published private(set) var isResuming = false
    @Published private(set) var resumeError: String?
    @Published private(set) var hosts: [WhubCore.Host] = []
    @Published private(set) var hostsError: String?

    private let context: ModelContext
    private let availableKinds: [AgentKind]
    private let runtime: AgentRuntime
    private let notify: (String) -> Void
    private var observations: [AgentBookTabStore.ID: AnyCancellable] = [:]
    private var pendingResume: AgentBookTabStore?
    private var pendingResumeSourceID: AgentBookTabStore.ID?

    init(context: ModelContext, kind: AgentKind = .codex,
         availableKinds: [AgentKind] = [.codex, .claudeCode],
         runtime: AgentRuntime? = nil,
         notify: @escaping (String) -> Void = { NSSound(named: $0)?.play() }) {
        let runtime = runtime ?? AgentRuntime()
        self.context = context
        self.availableKinds = availableKinds
        self.runtime = runtime
        self.notify = notify
        let localHost = try? HostStore(context: context).fetchHosts().first { $0 is LocalHost } as? LocalHost
        let tab = AgentBookTabStore(kind: kind, target: .local(host: localHost, runtime: runtime))
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

    func loadHosts() {
        do {
            hosts = try HostStore(context: context).fetchHosts()
            hostsError = nil
        } catch {
            hosts = []
            hostsError = error.localizedDescription
        }
    }

    func connect(_ id: AgentBookTabStore.ID, reconnect: Bool = false) async {
        guard let tab = tabs.first(where: { $0.id == id }),
              !tab.store.isClosed, !tab.store.isConnected || reconnect else { return }
        let directory = tab.store.historyEntry?.directory
            ?? tab.store.target.host?.basePath
            ?? NSHomeDirectory()
        await tab.store.connect(directory: directory, reconnect: reconnect)
    }

    func add() {
        let tab = AgentBookTabStore(kind: selectedTab.store.agentKind, target: selectedTab.store.target)
        tabs.append(tab)
        observe(tab)
        select(tab.id)
    }

    func canChangeKind(in id: AgentBookTabStore.ID) -> Bool {
        availableKinds.count > 1 && pendingResumeSourceID != id
            && tabs.first(where: { $0.id == id })?.canChangeKind == true
    }

    func canChangeHost(in id: AgentBookTabStore.ID) -> Bool {
        pendingResumeSourceID != id && tabs.first(where: { $0.id == id })?.canChangeKind == true
    }

    @discardableResult
    func changeHost(_ host: WhubCore.Host, in id: AgentBookTabStore.ID, servers: RemoteServerStore) -> Bool {
        guard canChangeHost(in: id), let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].store.target.host?.persistentModelID != host.persistentModelID else { return false }
        let target: AgentExecutionTarget
        switch host {
        case let local as LocalHost: target = .local(host: local, runtime: runtime)
        case let remote as RemoteHost: target = .remote(host: remote, servers: servers)
        default: return false
        }
        let replacement = AgentBookTabStore(kind: tabs[index].store.agentKind, target: target)
        replacement.store.draft = tabs[index].store.draft
        replacement.purpose = tabs[index].purpose
        close(tabs[index])
        tabs[index] = replacement
        observe(replacement)
        if selectedTabID == id { select(replacement.id) }
        return true
    }

    @discardableResult
    func changeKind(_ kind: AgentKind, in id: AgentBookTabStore.ID) -> Bool {
        guard availableKinds.contains(kind), canChangeKind(in: id),
              let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].store.agentKind != kind else { return false }
        let replacement = AgentBookTabStore(kind: kind, target: tabs[index].store.target)
        replacement.store.draft = tabs[index].store.draft
        close(tabs[index])
        tabs[index] = replacement
        observe(replacement)
        if selectedTabID == id { select(replacement.id) }
        return true
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
        let target = tabs[index].store.target
        close(tabs[index])
        if tabs.count == 1 {
            let replacement = AgentBookTabStore(kind: kind, target: target)
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
        let replacement = AgentBookTabStore(kind: tabs[index].store.agentKind, target: tabs[index].store.target)
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
        if let existing = openTab(for: entry, source: source.store) {
            return open(existing, replacing: sourceID)
        }

        let tab = AgentBookTabStore(kind: source.store.agentKind, target: source.store.target)
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
        let target = openTab(for: entry, source: source.store) ?? tab
        if target.id != tab.id { tab.disconnect() }
        return open(target, replacing: sourceID)
    }

    func disconnect() {
        cancelPendingResume()
        observations.removeAll()
        for tab in tabs { tab.disconnect() }
    }

    private func openTab(for entry: AgentHistoryEntry, source: AgentStore) -> AgentBookTabStore? {
        tabs.first {
            $0.store.agentKind == source.agentKind && $0.store.conversationID == entry.id
                && $0.store.target.host?.persistentModelID == source.target.host?.persistentModelID
        }
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
