import Foundation

public struct AgentSessionConfiguration: Codable, Sendable, Equatable {
    public let kind: AgentKind
    public let directory: String

    public init(kind: AgentKind, directory: String) {
        self.kind = kind
        self.directory = directory
    }
}

public struct AgentSessionState: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: AgentKind
    public let directory: String
    public let createdAt: Date
    public internal(set) var revision: UInt64 = 0
    public internal(set) var conversationID: String?
    public internal(set) var exchanges: [AgentExchange] = []
    public internal(set) var selectedModelOption: AgentModelOption?
    public internal(set) var commands: [AgentCommandReceipt] = []
    public internal(set) var error: AgentError?
    public internal(set) var isClosed = false
    public internal(set) var isResuming = false
    public internal(set) var isChangingModel = false
    public internal(set) var isSendingAdditionalInput = false
    public internal(set) var isStopping = false
    public internal(set) var respondingRequestIDs: Set<String> = []

    public var isRunning: Bool { exchanges.last?.status == .running }
}
