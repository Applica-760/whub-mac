import Foundation

public struct AgentExchange: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var input: [AgentInput]
    public var additionalInputs: [AgentAdditionalInput] = []
    public var outputs: [AgentOutput] = []
    public var status: AgentExecutionStatus = .running

    public var answers: [AgentOutput] { outputs.filter(\.isAnswer) }
    public var history: [AgentOutput] { outputs.filter { !$0.isAnswer } }
    public var pendingRequests: [AgentRequest] {
        outputs.compactMap { output in
            guard case .request(let request) = output, request.outcome == nil else { return nil }
            return request
        }
    }

    public init(id: UUID = UUID(), input: [AgentInput]) {
        self.id = id
        self.input = input
    }
}

public struct AgentAdditionalInput: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let input: [AgentInput]
    public let outputIndex: Int

    public init(id: UUID = UUID(), input: [AgentInput], outputIndex: Int) {
        self.id = id
        self.input = input
        self.outputIndex = outputIndex
    }
}

// MARK: - Output

public enum AgentOutput: Codable, Sendable, Equatable, Identifiable {
    case message(AgentMessage)
    case toolUse(AgentToolUse)
    case request(AgentRequest)

    public var id: String {
        switch self {
        case .message(let message): message.id
        case .toolUse(let toolUse): toolUse.id
        case .request(let request): request.id
        }
    }

    public var isAnswer: Bool {
        switch self {
        case .message(let message): message.role == .answer
        case .toolUse, .request: false
        }
    }
}

public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    // 接続側が安定したIDを割り当てる。Viewはプロトコル上の意味を解釈しない。
    public let id: String
    public var role: Role
    public var title: String
    public var content: AgentContent
    public var status: AgentExecutionStatus

    public enum Role: Codable, Sendable, Equatable {
        case answer
        case progress
    }
}

public struct AgentToolUse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let tool: AgentTool
    public var arguments: AgentContent?
    public var result: [AgentContent]?
    public var status: AgentExecutionStatus
}

public struct AgentTool: Codable, Sendable, Equatable {
    public let name: String
    public let source: String?

    init(name: String, source: String? = nil) {
        self.name = name
        self.source = source
    }
}

public enum AgentContent: Codable, Sendable, Equatable {
    case text(String)
    case markdown(String)
    case code(String)
    case image(AgentImageAttachment)
}

// MARK: - Request / Response

public struct AgentRequest: Codable, Sendable, Equatable, Identifiable {
    // RPC IDとの対応と回答の送信形式は、接続側で保持する。
    public let id: String
    public let kind: Kind
    public var outcome: AgentRequestOutcome?

    public var isApproval: Bool {
        if case .approval = kind { return true }
        return false
    }

    public enum Kind: Codable, Sendable, Equatable {
        case approval(AgentApprovalRequest)
        case questions([AgentQuestion])
    }
}

public struct AgentApprovalRequest: Codable, Sendable, Equatable {
    public let reason: String?
    public let command: String?
    public let directory: String?
    public let changePreview: String?
    public let permissionsDescription: String?
    // 整形済みの詳細。Viewは中身を解析せず、そのまま表示する。
    public let details: String?
}

public struct AgentQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let options: [Option]
    public let isSecret: Bool

    public struct Option: Codable, Sendable, Equatable {
        public let label: String
        public let description: String
    }
}

public enum AgentResponse: Codable, Sendable, Equatable {
    case approval(allow: Bool)
    case answers([String: String])
}

public enum AgentRequestOutcome: String, Codable, Sendable, Equatable {
    case accepted
    case declined
    case answered
    case resolved
    case unanswered
}

// MARK: - Status

public enum AgentExecutionStatus: String, Codable, Sendable, Equatable {
    case running
    case completed
    case failed
    case interrupted
}
