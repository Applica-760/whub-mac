import Foundation

struct CodexRecentThread: Identifiable {
    let id: String
    let name: String?
    let preview: String?
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
        name = data["name"] as? String
        preview = data["preview"] as? String
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
            var inputContent: [CodexPromptContent] = []
            for item in items where item["type"] as? String == "userMessage" {
                guard let content = item["content"] as? [[String: Any]] else {
                    throw CodexError(message: "会話の入力履歴が不正です。")
                }
                for input in content {
                    switch input["type"] as? String {
                    case "text":
                        guard let text = input["text"] as? String else { throw CodexError(message: "入力履歴の本文がありません。") }
                        inputContent.append(.text(text))
                    default:
                        inputContent.append(.attachment(type: input["type"] as? String, name: input["name"] as? String))
                    }
                }
            }
            var turn = CodexTurn(remoteID: id, prompt: "", status: status)
            turn.input = inputContent
            for item in items {
                guard item["id"] is String, item["type"] is String else {
                    throw CodexError(message: "会話履歴の項目が不正です。")
                }
                turn.updateItem(item, completed: true)
            }
            turn.inferFinalAnswerIfNeeded()
            return turn
        }
        directory = cwd
        self.model = model
    }
}
