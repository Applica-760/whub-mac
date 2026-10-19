import AppKit
import Foundation
import WhubAgent

typealias AgentKind = WhubAgent.AgentKind
typealias AgentSkill = WhubAgent.AgentSkill
typealias AgentTool = WhubAgent.AgentTool
typealias AgentRequest = WhubAgent.AgentRequest
typealias AgentApprovalRequest = WhubAgent.AgentApprovalRequest
typealias AgentQuestion = WhubAgent.AgentQuestion
typealias AgentResponse = WhubAgent.AgentResponse
typealias AgentRequestOutcome = WhubAgent.AgentRequestOutcome
typealias AgentExecutionStatus = WhubAgent.AgentExecutionStatus

// MARK: - Exchange

struct AgentExchange: Identifiable {
    let id: UUID
    var input: [AgentInput]
    var additionalInputs: [AgentAdditionalInput] = []
    var outputs: [AgentOutput] = []
    var status: AgentExecutionStatus = .running

    var answers: [AgentOutput] { outputs.filter(\.isAnswer) }
    var history: [AgentOutput] { outputs.filter { !$0.isAnswer } }
    var pendingRequests: [AgentRequest] {
        outputs.compactMap { output in
            guard case .request(let request) = output, request.outcome == nil else { return nil }
            return request
        }
    }

    init(id: UUID = UUID(), input: [AgentInput]) {
        self.id = id
        self.input = input
    }
}

struct AgentAdditionalInput: Identifiable {
    let id: UUID
    let input: [AgentInput]
    let outputIndex: Int

    init(id: UUID = UUID(), input: [AgentInput], outputIndex: Int) {
        self.id = id
        self.input = input
        self.outputIndex = outputIndex
    }
}

// MARK: - Input

enum AgentInput: Equatable {
    case text(String)
    case skill(AgentSkill)
    case image(AgentImageAttachment)
    case slashCommand(AgentSlashCommand)
}

struct AgentImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: NSImage

    init(id: UUID = UUID(), image: NSImage) {
        self.id = id
        self.image = image
    }
}

enum AgentSlashCommand: String, CaseIterable {
    case new = "/new"
    case stop = "/stop"
    case skills = "/skills"
    case status = "/status"
    case model = "/model"
    case resume = "/resume"
}

// MARK: - Output

enum AgentOutput: Identifiable {
    case message(AgentMessage)
    case toolUse(AgentToolUse)
    case request(AgentRequest)
    case slashCommandResult(AgentSlashCommandResult)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .toolUse(let toolUse): toolUse.id
        case .request(let request): request.id
        case .slashCommandResult(let result): result.id
        }
    }

    var isAnswer: Bool {
        switch self {
        case .message(let message): message.role == .answer
        case .slashCommandResult: true
        case .toolUse, .request: false
        }
    }
}

struct AgentMessage: Identifiable {
    // 接続側が安定したIDを割り当てる。Viewはプロトコル上の意味を解釈しない。
    let id: String
    var role: Role
    var title: String
    var content: AgentContent
    var status: AgentExecutionStatus

    typealias Role = WhubAgent.AgentMessage.Role
}

struct AgentToolUse: Identifiable {
    let id: String
    let tool: AgentTool
    var arguments: AgentContent?
    var result: [AgentContent]?
    var status: AgentExecutionStatus
}

struct AgentSlashCommandResult: Identifiable {
    let id: String
    let command: AgentSlashCommand
    var content: [AgentContent]
    var status: AgentExecutionStatus
}

enum AgentContent: Equatable {
    case text(String)
    case markdown(String)
    case code(String)
    case image(AgentImageAttachment)
}
