import Foundation

extension CodexRecentThread {
    var displayTitle: String {
        [name, preview].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? id
    }
}

extension CodexTurn {
    var displayPrompt: String {
        input.map { content in
            switch content {
            case let .text(text): return text
            case let .attachment(type, name):
                if type == "skill" || type == "mention" { return name ?? "添付参照" }
                return "［添付: \(type ?? "不明")］"
            }
        }.joined(separator: "\n")
    }
}

extension CodexItem {
    var displayTitle: String {
        switch type {
        case "agentMessage": return "進捗メッセージ"
        case "commandExecution": return data["command"] as? String ?? "コマンド実行"
        case "commandOutput": return data["command"] as? String ?? type
        case "fileChange": return "ファイル変更"
        case "webSearch": return "Web検索 · " + (data["query"] as? String ?? "")
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall": return data["tool"] as? String ?? type
        case "plan": return "計画"
        case "contextCompaction": return "会話を圧縮"
        default: return type
        }
    }

    static func changePreview(_ changes: [[String: Any]]) -> String {
        changes.map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }
            .joined(separator: "\n\n")
    }

    var displayText: String {
        if let output { return output.displayText }
        if type == "fileChange" { return Self.changePreview(data["changes"] as? [[String: Any]] ?? []) }
        let fallback = type == "agentMessage" || type == "commandExecution" ? "" : CodexJSON.pretty(data)
        return (text ?? fallback) + delta
    }

    var displayMarkdown: String {
        type == "commandOutput" ? CodexCommandPresentation.codeBlock(displayText) : displayText
    }
}

extension CodexRequestOutcome {
    var displayText: String {
        switch self {
        case .accepted: "承認済み"
        case .declined: "拒否済み"
        case .answered: "回答済み"
        case .resolved: "解決済み"
        case .unanswered: "終了（未回答）"
        }
    }
}
