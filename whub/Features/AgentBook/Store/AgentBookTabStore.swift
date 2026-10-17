import Combine
import Foundation

@MainActor
final class AgentBookTabStore: ObservableObject, Identifiable {
    nonisolated let id: AgentStore.ID
    let store: AgentStore
    let skillStore: AgentSkillStore
    let historyStore: AgentHistoryStore
    @Published private(set) var hasCompleted = false
    @Published private(set) var notificationDate: Date?
    var onNotification: ((String) -> Void)?

    private var observation: AnyCancellable?

    init(session: any AgentSession) {
        let store = AgentStore(session: session)
        id = store.id
        self.store = store
        skillStore = AgentSkillStore(session: session)
        historyStore = AgentHistoryStore(session: session)
        observe()
    }

    var canReplace: Bool {
        !store.isConnecting && !store.isBusy && !store.isSendingAdditionalInput
            && !store.isResuming && !store.isChangingModel && store.respondingRequestIDs.isEmpty
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
