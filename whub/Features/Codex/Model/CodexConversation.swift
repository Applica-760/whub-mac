import AppKit
import Foundation

struct CodexItem: Identifiable {
    let id: String
    var type: String
    var phase: String?
    var title: String
    var text: String
    var status: String
    var isAnswer: Bool { type == "commandOutput" || (type == "agentMessage" && phase == "final_answer") }
}

enum CodexPromptContent: Equatable {
    case text(String)
    case attachment(type: String?, name: String?)
}

struct CodexTurn: Identifiable {
    let id = UUID()
    var remoteID: String?
    var input: [CodexPromptContent]
    var images: [CodexImageAttachment] = []
    var approvals: [CodexRequest] = []
    var items: [CodexItem] = []
    var status = "inProgress"
    var history: [CodexItem] { items.filter { !$0.isAnswer } }
    var answers: [CodexItem] { items.filter(\.isAnswer) }

    init(remoteID: String? = nil, prompt: String, images: [CodexImageAttachment] = [],
         items: [CodexItem] = [], status: String = "inProgress") {
        self.remoteID = remoteID
        input = [.text(prompt)]
        self.images = images
        self.items = items
        self.status = status
    }

    mutating func updateItem(_ data: [String: Any], completed: Bool) {
        guard let id = data["id"] as? String, let type = data["type"] as? String,
              type != "userMessage", type != "reasoning" else { return }
        let existing = items.firstIndex { $0.id == id }
        var title = type
        var text = data["text"] as? String
        switch type {
        case "agentMessage": title = "進捗メッセージ"
        case "commandExecution":
            title = data["command"] as? String ?? "コマンド実行"
            text = data["aggregatedOutput"] as? String
        case "fileChange":
            title = "ファイル変更"
            text = (data["changes"] as? [[String: Any]] ?? []).map {
                ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "")
            }.joined(separator: "\n\n")
        case "webSearch": title = "Web検索 · " + (data["query"] as? String ?? "")
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            title = data["tool"] as? String ?? type
        case "plan": title = "計画"
        case "contextCompaction": title = "会話を圧縮"
        default: break
        }
        if text == nil, type != "agentMessage", type != "commandExecution" {
            text = CodexStore.pretty(data)
        }
        let item = CodexItem(id: id, type: type, phase: data["phase"] as? String,
                             title: title, text: text ?? existing.map { items[$0].text } ?? "",
                             status: data["status"] as? String ?? (completed ? "completed" : "inProgress"))
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

struct CodexRequest: Identifiable {
    let rpcID: Any
    let method: String
    let params: [String: Any]
    var outcome: String? = nil
    var isApproval: Bool { method != "item/tool/requestUserInput" }
    var id: String { CodexStore.pretty(rpcID) }
}

struct CodexImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let pngData: Data

    init?(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        self.image = image
        pngData = png
    }

    var input: [String: String] {
        ["type": "image", "url": "data:image/png;base64," + pngData.base64EncodedString()]
    }
}
