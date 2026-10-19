import Foundation

public struct AgentCommand: Identifiable, Codable, Sendable, Equatable {
    public enum Action: Codable, Sendable, Equatable {
        case send([AgentInput])
        case sendAdditionalInput([AgentInput])
        case interrupt
        case respond(requestID: String, response: AgentResponse)
        case changeModel(AgentModelOption)
        case resume(AgentHistoryEntry)
    }

    public let id: UUID
    public let action: Action

    public init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }
}

public struct AgentCommandReceipt: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case accepted, completed, failed
    }

    public let id: UUID
    public internal(set) var status: Status
    public internal(set) var error: AgentError?
}
