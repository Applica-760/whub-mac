import Combine
import Foundation
import WhubAgent

@MainActor
final class AgentSkillStore: ObservableObject {
    @Published private(set) var skills: [AgentSkill] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let agent: AgentStore

    // 接続の開始・終了はAgentStoreが担当する。
    init(agent: AgentStore) {
        self.agent = agent
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedSkills = try await agent.loadSkills()
            guard !Task.isCancelled else { return }
            skills = loadedSkills
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
