import Combine
import Foundation

@MainActor
final class AgentSkillStore: ObservableObject {
    @Published private(set) var skills: [AgentSkill] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let session: any AgentSession

    // 接続の開始・終了はAgentStoreが担当する。
    init(session: any AgentSession) {
        self.session = session
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loadedSkills = try await session.loadSkills()
            guard !Task.isCancelled else { return }
            skills = loadedSkills
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
