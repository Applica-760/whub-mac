import AppKit
import Foundation

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
    let id = UUID()
    let input: [AgentInput]
    let outputIndex: Int
}

// MARK: - Input

enum AgentInput: Equatable {
    case text(String)
    case skill(AgentSkill)
    case image(AgentImageAttachment)
    case slashCommand(AgentSlashCommand)
}

struct AgentSkill: Identifiable, Equatable {
    // 接続側が識別子を割り当て、実際の呼び出し先との対応を管理する。
    let id: String
    let name: String
    let description: String
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

    enum Role {
        case answer
        case progress
    }
}

struct AgentToolUse: Identifiable {
    let id: String
    let tool: AgentTool
    var arguments: AgentContent?
    var result: [AgentContent]?
    var status: AgentExecutionStatus
}

struct AgentTool {
    let name: String
    let source: String?

    init(name: String, source: String? = nil) {
        self.name = name
        self.source = source
    }
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

// MARK: - Request / Response

struct AgentRequest: Identifiable {
    // RPC IDとの対応と回答の送信形式は、接続側で保持する。
    let id: String
    let kind: Kind
    var outcome: AgentRequestOutcome?

    var isApproval: Bool {
        if case .approval = kind { return true }
        return false
    }

    enum Kind {
        case approval(AgentApprovalRequest)
        case questions([AgentQuestion])
    }
}

struct AgentApprovalRequest {
    let reason: String?
    let command: String?
    let directory: String?
    let changePreview: String?
    let permissionsDescription: String?
    // 整形済みの詳細。Viewは中身を解析せず、そのまま表示する。
    let details: String?
}

struct AgentQuestion: Identifiable {
    let id: String
    let prompt: String
    let options: [Option]
    let isSecret: Bool

    struct Option {
        let label: String
        let description: String
    }
}

enum AgentResponse {
    case approval(allow: Bool)
    case answers([String: String])
}

enum AgentRequestOutcome {
    case accepted
    case declined
    case answered
    case resolved
    case unanswered
}

// MARK: - Status

enum AgentExecutionStatus {
    case running
    case completed
    case failed
    case interrupted
}
