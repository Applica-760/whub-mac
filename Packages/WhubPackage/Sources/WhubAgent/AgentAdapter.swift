import Foundation

enum AgentEvent: Sendable {
    case conversationIDChanged(String)
    case modelOptionChanged(AgentModelOption)
    case output(AgentOutput)
    case completed
    case interrupted
    case failed(String)
}

// The runtime consumes this stream even when no UI or HTTP client is connected.
@MainActor
protocol AgentAdapter: AnyObject {
    var kind: AgentKind { get }
    var events: AsyncStream<AgentEvent> { get }
    func connect(directory: String) async throws
    func send(_ input: [AgentInput]) async throws
    func sendAdditionalInput(_ input: [AgentInput]) async throws
    func interrupt() async throws
    func loadModelOptions() async throws -> [AgentModelOption]
    func loadSkills() async throws -> [AgentSkill]
    func loadStatus() async throws -> [AgentContent]
    func changeModel(_ option: AgentModelOption) async throws
    func respond(to requestID: String, with response: AgentResponse) async throws
    func loadHistory(cursor: String?) async throws -> AgentHistoryPage
    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot
    func close()
}
