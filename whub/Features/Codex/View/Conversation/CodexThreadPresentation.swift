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
