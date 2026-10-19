import Combine
import Foundation
import WhubAgent

@MainActor
final class AgentHistoryStore: ObservableObject {
    @Published private(set) var entries: [AgentHistoryEntry] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let agent: AgentStore

    // 接続の開始・終了はAgentStoreが担当する。
    init(agent: AgentStore) {
        self.agent = agent
    }

    func load(more: Bool = false) async {
        guard !isLoading, !more || nextCursor != nil else { return }
        let cursor = more ? nextCursor : nil
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await agent.loadHistory(cursor: cursor)
            guard !Task.isCancelled else { return }
            var seen = Set(more ? entries.map(\.id) : [])
            let additions = page.entries.filter { seen.insert($0.id).inserted }
            entries = (more ? entries : []) + additions
            nextCursor = page.nextCursor
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
