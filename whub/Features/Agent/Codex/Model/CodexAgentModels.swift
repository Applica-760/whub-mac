import Foundation

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

