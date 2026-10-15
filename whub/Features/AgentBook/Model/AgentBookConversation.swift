import AppKit
import Foundation

struct AgentBookTurn: Identifiable {
    let id: UUID
    var input: [AgentBookPromptContent]
    var approvals: [AgentBookRequest] = []
    var items: [AgentBookItem] = []
    var status: AgentBookExecutionStatus = .running

    var answers: [AgentBookItem] { items.filter { $0.role == .answer } }
    var history: [AgentBookItem] { items.filter { $0.role == .activity } }

    init(id: UUID = UUID(), input: [AgentBookPromptContent]) {
        self.id = id
        self.input = input
    }
}

enum AgentBookPromptContent: Equatable {
    case text(String)
    case skill(name: String)
    case image(AgentBookImageAttachment)
}

struct AgentBookImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: NSImage

    init(id: UUID = UUID(), image: NSImage) {
        self.id = id
        self.image = image
    }
}

enum AgentBookExecutionStatus {
    case running
    case completed
    case failed
    case interrupted
}

struct AgentBookItem: Identifiable {
    // 接続側が安定したIDを割り当てる。Viewはプロトコル上の意味を解釈しない。
    let id: String
    var role: Role
    var title: String
    var content: AgentBookContent
    var status: AgentBookExecutionStatus

    enum Role {
        case answer
        case activity
    }
}

enum AgentBookContent: Equatable {
    case text(String)
    case markdown(String)
    case code(String)
}

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
        case approval(AgentBookApproval)
        case questions([AgentBookQuestion])
    }
}

struct AgentBookApproval {
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
