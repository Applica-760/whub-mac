import Foundation

struct AgentHistoryEntry: Identifiable {
    let id: String
    let name: String?
    let preview: String?
    let directory: String
    let updatedAt: Date
}

struct AgentHistoryPage {
    let entries: [AgentHistoryEntry]
    let nextCursor: String?
}

struct AgentHistorySnapshot {
    let entry: AgentHistoryEntry
    let exchanges: [AgentExchange]
    let selectedModelOption: AgentModelOption?
}
