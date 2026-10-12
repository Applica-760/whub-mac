import Foundation

struct CodexRecentThread: Identifiable {
    let id: String
    let title: String
    let directory: String
    let updatedAt: Date

    init(_ data: [String: Any]) throws {
        guard let id = data["id"] as? String, !id.isEmpty,
              let directory = data["cwd"] as? String, directory.hasPrefix("/"),
              let updatedAt = data["updatedAt"] as? Double else {
            throw CodexError(message: "会話一覧の形式が不正です。")
        }
        self.id = id
        self.directory = directory
        self.updatedAt = Date(timeIntervalSince1970: updatedAt)
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (data["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = [name, preview].compactMap { $0 }.first { !$0.isEmpty } ?? id
    }
}

struct CodexThreadHistory {
    let directory: String
    let model: String
    let turns: [CodexTurn]

    init(_ result: [String: Any], expectedID: String) throws {
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == expectedID,
              let cwd = result["cwd"] as? String, cwd.hasPrefix("/"),
              let model = result["model"] as? String,
              let history = thread["turns"] as? [[String: Any]] else {
            throw CodexError(message: "再開する会話の情報が不正です。")
        }
        turns = try history.map { data -> CodexTurn in
            guard let id = data["id"] as? String, let status = data["status"] as? String,
                  ["completed", "interrupted", "failed"].contains(status),
                  (data["itemsView"] as? String ?? "full") == "full",
                  let items = data["items"] as? [[String: Any]] else {
                throw CodexError(message: "履歴が不完全か、会話が実行中です。作業の終了後に再試行してください。")
            }
            var prompt: [String] = []
            for item in items where item["type"] as? String == "userMessage" {
                guard let content = item["content"] as? [[String: Any]] else {
                    throw CodexError(message: "会話の入力履歴が不正です。")
                }
                for input in content {
                    switch input["type"] as? String {
                    case "text":
                        guard let text = input["text"] as? String else { throw CodexError(message: "入力履歴の本文がありません。") }
                        prompt.append(text)
                    case "skill", "mention": prompt.append(input["name"] as? String ?? "添付参照")
                    default: prompt.append("［添付: \(input["type"] as? String ?? "不明")］")
                    }
                }
            }
            var turn = CodexTurn(remoteID: id, prompt: prompt.joined(separator: "\n"), status: status)
            for item in items {
                guard item["id"] is String, item["type"] is String else {
                    throw CodexError(message: "会話履歴の項目が不正です。")
                }
                turn.updateItem(item, completed: true)
            }
            if turn.answers.isEmpty, let last = turn.items.lastIndex(where: { $0.type == "agentMessage" && $0.phase == nil }) {
                turn.items[last].phase = "final_answer"
            }
            return turn
        }
        directory = cwd
        self.model = model
    }
}
