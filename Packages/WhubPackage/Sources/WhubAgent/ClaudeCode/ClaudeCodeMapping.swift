import Foundation

enum ClaudeCodeMapping {
    static func input(_ input: [AgentInput]) throws -> [[String: Any]] {
        try input.map { item in
            guard case .text(let text) = item else {
                throw AgentError(.unsupported, "Claude Codeへの入力はテキストのみ対応しています。")
            }
            return ["type": "text", "text": text]
        }
    }

    static func output(_ item: ClaudeCodeItem) -> AgentOutput {
        if item.type == "text" {
            return .message(AgentMessage(id: item.id, role: item.isAnswer ? .answer : .progress,
                title: "進捗メッセージ", content: .markdown(item.text ?? item.delta), status: item.status))
        }
        let command = (item.input as? [String: Any])?["command"] as? String
        return .toolUse(AgentToolUse(id: item.id,
            tool: AgentTool(name: item.name == "Bash" ? command ?? item.name : item.name),
            arguments: item.input.map { .code(AgentJSON.pretty($0)) } ?? (item.delta.isEmpty ? nil : .code(item.delta)),
            result: item.result.map { [.code($0)] }, status: item.status))
    }

    static func text(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
