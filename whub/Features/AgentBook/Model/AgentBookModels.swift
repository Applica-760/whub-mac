import AppKit
import Foundation

// MARK: - Exchange

struct AgentBookExchange: Identifiable {
    let id: UUID
    var input: [AgentBookInput]
    var outputs: [AgentBookOutput] = []
    var status: AgentBookExecutionStatus = .running

    var answers: [AgentBookOutput] { outputs.filter(\.isAnswer) }
    var history: [AgentBookOutput] { outputs.filter { !$0.isAnswer } }
    var pendingRequests: [AgentBookRequest] {
        outputs.compactMap { output in
            guard case .request(let request) = output, request.outcome == nil else { return nil }
            return request
        }
    }

    init(id: UUID = UUID(), input: [AgentBookInput]) {
        self.id = id
        self.input = input
    }
}

// MARK: - Input

enum AgentBookInput: Equatable {
    case text(String)
    case skill(name: String)
    case image(AgentBookImageAttachment)
    case command(AgentBookCommand)
}

struct AgentBookImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: NSImage

    init(id: UUID = UUID(), image: NSImage) {
        self.id = id
        self.image = image
    }
}

enum AgentBookCommand: String, CaseIterable {
    case new = "/new"
    case stop = "/stop"
    case skills = "/skills"
    case status = "/status"
    case model = "/model"
    case resume = "/resume"
}

// MARK: - Output

enum AgentBookOutput: Identifiable {
    case message(AgentBookMessage)
    case toolUse(AgentBookToolUse)
    case request(AgentBookRequest)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .toolUse(let toolUse): toolUse.id
        case .request(let request): request.id
        }
    }

    var isAnswer: Bool {
        if case .message(let message) = self { return message.role == .answer }
        return false
    }
}

struct AgentBookMessage: Identifiable {
    // 接続側が安定したIDを割り当てる。Viewはプロトコル上の意味を解釈しない。
    let id: String
    var role: Role
    var title: String
    var content: AgentBookContent
    var status: AgentBookExecutionStatus

    enum Role {
        case answer
        case progress
    }
}

struct AgentBookToolUse: Identifiable {
    let id: String
    let tool: AgentBookTool
    var arguments: AgentBookContent?
    var result: [AgentBookContent]?
    var status: AgentBookExecutionStatus
}

struct AgentBookTool {
    let name: String
    let source: String?

    init(name: String, source: String? = nil) {
        self.name = name
        self.source = source
    }
}

enum AgentBookContent: Equatable {
    case text(String)
    case markdown(String)
    case code(String)
    case image(AgentBookImageAttachment)
}

// MARK: - Request / Response

struct AgentBookRequest: Identifiable {
    // RPC IDとの対応と回答の送信形式は、接続側で保持する。
    let id: String
    let kind: Kind
    var outcome: AgentBookRequestOutcome?

    var isApproval: Bool {
        if case .approval = kind { return true }
        return false
    }

    enum Kind {
        case approval(AgentBookApprovalRequest)
        case questions([AgentBookQuestion])
    }
}

struct AgentBookApprovalRequest {
    let reason: String?
    let command: String?
    let directory: String?
    let changePreview: String?
    let permissionsDescription: String?
    // 整形済みの詳細。Viewは中身を解析せず、そのまま表示する。
    let details: String?
}

struct AgentBookQuestion: Identifiable {
    let id: String
    let prompt: String
    let options: [Option]
    let isSecret: Bool

    struct Option {
        let label: String
        let description: String
    }
}

enum AgentBookResponse {
    case approval(allow: Bool)
    case answers([String: String])
}

enum AgentBookRequestOutcome {
    case accepted
    case declined
    case answered
    case resolved
    case unanswered
}

// MARK: - Status

enum AgentBookExecutionStatus {
    case running
    case completed
    case failed
    case interrupted
}
