import Foundation

nonisolated enum CodexAgentJSON {
    static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}


struct CodexAgentModel: Identifiable {
    let id: String
    let options: [AgentModelOption]
    let supportsImages: Bool
    let isDefault: Bool

    init(_ data: [String: Any]) throws {
        guard let id = data["id"] as? String, !id.isEmpty,
              let model = data["model"] as? String, !model.isEmpty,
              let displayName = data["displayName"] as? String,
              let defaultEffort = data["defaultReasoningEffort"] as? String,
              let efforts = data["supportedReasoningEfforts"] as? [[String: Any]] else {
            throw CodexAgentError(message: "モデル一覧の形式が不正です。")
        }
        let description = data["description"] as? String ?? ""
        var parsed = try efforts.map { effort -> AgentModelOption in
            guard let value = effort["reasoningEffort"] as? String, !value.isEmpty else {
                throw CodexAgentError(message: "推論設定の形式が不正です。")
            }
            let detail = effort["description"] as? String ?? ""
            return AgentModelOption(id: CodexAgentJSON.pretty([id, value]), modelID: model,
                displayName: displayName, description: detail.isEmpty ? description : detail,
                effort: value, isDefaultEffort: value == defaultEffort)
        }
        if parsed.isEmpty {
            parsed = [AgentModelOption(id: CodexAgentJSON.pretty([id, defaultEffort]), modelID: model,
                displayName: displayName, description: description,
                effort: defaultEffort, isDefaultEffort: true)]
        }
        guard parsed.contains(where: \.isDefaultEffort),
              Set(parsed.map(\.id)).count == parsed.count else {
            throw CodexAgentError(message: "モデルの既定推論設定を確認できませんでした。")
        }
        self.id = id
        options = parsed
        supportsImages = (data["inputModalities"] as? [String] ?? ["text", "image"]).contains("image")
        isDefault = data["isDefault"] as? Bool ?? false
    }
}


struct CodexAgentItem: Identifiable {
    let id: String
    var type: String
    var phase: String?
    var text: String?
    var status: String
    var data: [String: Any] = [:]
    var delta = ""
    var isAnswer: Bool { type == "commandOutput" || (type == "agentMessage" && phase == "final_answer") }
}

struct CodexAgentTurn: Identifiable {
    let id = UUID()
    var remoteID: String?
    var items: [CodexAgentItem] = []
    var answers: [CodexAgentItem] { items.filter(\.isAnswer) }

    mutating func updateItem(_ data: [String: Any], completed: Bool) {
        guard let id = data["id"] as? String, let type = data["type"] as? String,
              type != "userMessage", type != "reasoning" else { return }
        let existing = items.firstIndex { $0.id == id }
        let text = type == "commandExecution" ? data["aggregatedOutput"] as? String : data["text"] as? String
        let keepsStreamedText = text == nil && (type == "agentMessage" || type == "commandExecution")
        let previous = existing.map { items[$0] }
        let item = CodexAgentItem(id: id, type: type, phase: data["phase"] as? String,
                             text: text ?? (keepsStreamedText ? previous?.text : nil),
                             status: data["status"] as? String ?? (completed ? "completed" : "inProgress"),
                             data: data, delta: keepsStreamedText ? previous?.delta ?? "" : "")
        if let existing { items[existing] = item } else { items.append(item) }
    }

    mutating func inferFinalAnswerIfNeeded() {
        // Older models omit phase; only the last non-commentary message is the answer.
        if answers.isEmpty,
           let last = items.lastIndex(where: { $0.type == "agentMessage" && $0.phase == nil }) {
            items[last].phase = "final_answer"
        }
    }
}

