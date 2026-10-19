import Combine
import Foundation
import WhubAgent

enum AgentBookTabPurpose: String, CaseIterable, Identifiable {
    case featureDevelopment
    case debugging
    case investigation
    case personalDevelopment
    case internship
    case research
    case modeling

    var id: String { rawValue }

    var title: String {
        switch self {
        case .featureDevelopment: "機能追加"
        case .debugging: "デバッグ"
        case .investigation: "調査"
        case .personalDevelopment: "個人開発"
        case .internship: "インターン"
        case .research: "研究"
        case .modeling: "モデリング"
        }
    }

    var symbol: String {
        switch self {
        case .featureDevelopment: "hammer"
        case .debugging: "ladybug"
        case .investigation: "text.magnifyingglass"
        case .personalDevelopment: "laptopcomputer"
        case .internship: "briefcase"
        case .research: "graduationcap"
        case .modeling: "cube.transparent"
        }
    }
}

@MainActor
final class AgentBookTabStore: ObservableObject, Identifiable {
    nonisolated let id: AgentStore.ID
    let store: AgentStore
    let skillStore: AgentSkillStore
    let historyStore: AgentHistoryStore
    @Published private(set) var hasCompleted = false
    @Published private(set) var notificationDate: Date?
    @Published var purpose: AgentBookTabPurpose?
    var onNotification: ((String) -> Void)?

    private var observation: AnyCancellable?

    init(kind: AgentKind, runtime: AgentRuntime) {
        let store = AgentStore(kind: kind, runtime: runtime)
        id = store.id
        self.store = store
        skillStore = AgentSkillStore(agent: store)
        historyStore = AgentHistoryStore(agent: store)
        observe()
    }

    var canReplace: Bool {
        !store.isConnecting && !store.isBusy && !store.isSendingAdditionalInput
            && !store.isResuming && !store.isChangingModel && store.respondingRequestIDs.isEmpty
    }

    var canChangeKind: Bool {
        canReplace && !store.isClosed && store.conversationID == nil
            && store.historyEntry == nil && store.exchanges.isEmpty
    }

    func markRead() {
        hasCompleted = false
    }

    func disconnect() {
        observation = nil
        onNotification = nil
        store.disconnect()
    }

    private func observe() {
        var runningIDs: Set<AgentExchange.ID> = []
        var approvalIDs: Set<String> = []
        observation = store.$exchanges.sink { [weak self] exchanges in
            guard let self else { return }
            let running = exchanges.filter { $0.status == .running }
            let nextRunningIDs = Set(running.map(\.id))
            let nextApprovalIDs = Set(running.flatMap(\.pendingRequests).filter(\.isApproval).map(\.id))
            if !nextRunningIDs.subtracting(runningIDs).isEmpty { self.hasCompleted = false }
            if exchanges.contains(where: { runningIDs.contains($0.id) && $0.status == .completed }) {
                self.hasCompleted = true
                self.notificationDate = Date()
                self.onNotification?("Glass")
            }
            for _ in nextApprovalIDs.subtracting(approvalIDs) {
                self.notificationDate = Date()
                self.onNotification?("Blow")
            }
            runningIDs = nextRunningIDs
            approvalIDs = nextApprovalIDs
        }
    }
}
