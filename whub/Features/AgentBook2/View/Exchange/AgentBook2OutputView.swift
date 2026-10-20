import SwiftUI
import WhubAgent

// Work history keeps the existing disclosure rows; answers use the book document.
struct AgentBook2OutputView: View {
    let output: AgentOutput

    var body: some View {
        DisclosureGroup {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(output.agentBook2Text.isEmpty ? "出力なし" : output.agentBook2Text)
                }
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
        } label: {
            Label(output.agentBook2Title, systemImage: output.agentBook2Status == .failed ? "xmark.circle" : "terminal")
                .lineLimit(2)
        }
        .focusEffectDisabled()
    }
}

extension AgentOutput {
    var agentBook2Content: [AgentContent] {
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

    var agentBook2Markdown: String { agentBook2Content.map(\.agentBook2Markdown).joined(separator: "\n\n") }

    var agentBook2Text: String { agentBook2Content.map(\.agentBook2Text).joined(separator: "\n\n") }

    var agentBook2Title: String {
        switch self {
        case .message(let message): message.title
        case .toolUse(let tool): tool.tool.name
        case .request(let request): request.isApproval ? "実行リクエスト" : "回答が必要です"
        case .slashCommandResult(let result): result.command.rawValue
        }
    }

    var agentBook2Status: AgentExecutionStatus? {
        switch self {
        case .message(let message): message.status
        case .toolUse(let tool): tool.status
        case .slashCommandResult(let result): result.status
        case .request: nil
        }
    }
}

extension AgentContent {
    var agentBook2Markdown: String {
        guard case .code(let source) = self else { return agentBook2Text }
        let longest = source.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + source + "\n" + fence
    }

    var agentBook2Text: String {
        switch self {
        case .text(let text), .markdown(let text), .code(let text): text
        case .image: "［画像］"
        }
    }
}

extension AgentRequestOutcome {
    var agentBook2Text: String {
        switch self {
        case .accepted: "承認済み"
        case .declined: "拒否済み"
        case .answered: "回答済み"
        case .resolved: "解決済み"
        case .unanswered: "終了（未回答）"
        }
    }
}
