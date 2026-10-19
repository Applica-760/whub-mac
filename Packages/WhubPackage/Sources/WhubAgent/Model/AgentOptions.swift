import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case codex, claudeCode
}

public struct AgentSkill: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct AgentModelOption: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let modelID: String
    public let displayName: String
    public let description: String
    public let effort: String?
    public let isDefaultEffort: Bool

    public init(id: String, modelID: String, displayName: String, description: String,
                effort: String?, isDefaultEffort: Bool) {
        self.id = id
        self.modelID = modelID
        self.displayName = displayName
        self.description = description
        self.effort = effort
        self.isDefaultEffort = isDefaultEffort
    }
}

public struct AgentHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let preview: String?
    public let directory: String
    public let updatedAt: Date

    public init(id: String, name: String?, preview: String?, directory: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.preview = preview
        self.directory = directory
        self.updatedAt = updatedAt
    }
}

public struct AgentHistoryPage: Codable, Sendable, Equatable {
    public let entries: [AgentHistoryEntry]
    public let nextCursor: String?
}

struct AgentHistorySnapshot: Sendable {
    let entry: AgentHistoryEntry
    let exchanges: [AgentExchange]
    let selectedModelOption: AgentModelOption?
}
