import SwiftUI

// Work history keeps the existing disclosure rows; answers use the book document.
struct AgentBookOutputView: View {
    let output: AgentOutput

    var body: some View {
        DisclosureGroup {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    if case .toolUse = output { Text(output.agentBookTitle).bold() }
                    Text(output.agentBookText.isEmpty ? "出力なし" : output.agentBookText)
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
        } label: {
            Label(output.agentBookTitle, systemImage: output.agentBookStatus == .failed ? "xmark.circle" : "terminal")
                .lineLimit(2)
        }
        .focusEffectDisabled()
    }
}

extension AgentOutput {
    var agentBookContent: [AgentContent] {
        switch self {
        case .message(let message): [message.content]
        case .toolUse(let tool): (tool.arguments.map { [$0] } ?? []) + (tool.result ?? [])
        case .slashCommandResult(let result): result.content
        case .request(let request):
            switch request.kind {
            case .approval(let approval):
                [approval.reason, approval.command, approval.directory, approval.changePreview,
                 approval.permissionsDescription, approval.details].compactMap { $0 }.map(AgentContent.text)
            case .questions(let questions): questions.map { .text($0.prompt) }
            }
        }
    }

    var agentBookMarkdown: String { agentBookContent.map(\.agentBookMarkdown).joined(separator: "\n\n") }

    var agentBookText: String { agentBookContent.map(\.agentBookText).joined(separator: "\n\n") }

    var agentBookTitle: String {
        switch self {
        case .message(let message): message.title
        case .toolUse(let tool): tool.tool.name
        case .request(let request): request.isApproval ? "実行リクエスト" : "回答が必要です"
        case .slashCommandResult(let result): result.command.rawValue
        }
    }

    var agentBookStatus: AgentExecutionStatus? {
        switch self {
        case .message(let message): message.status
        case .toolUse(let tool): tool.status
        case .slashCommandResult(let result): result.status
        case .request: nil
        }
    }
}

extension AgentContent {
    var agentBookMarkdown: String {
        guard case .code(let source) = self else { return agentBookText }
        let longest = source.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + source + "\n" + fence
    }

    var agentBookText: String {
        switch self {
        case .text(let text), .markdown(let text), .code(let text): text
        case .image: "［画像］"
        }
    }
}

extension AgentRequestOutcome {
    var agentBookText: String {
        switch self {
        case .accepted: "承認済み"
        case .declined: "拒否済み"
        case .answered: "回答済み"
        case .resolved: "解決済み"
        case .unanswered: "終了（未回答）"
        }
    }
}
