import AppKit
import Foundation

struct CodexItem: Identifiable {
    let id: String
    var type: String
    var phase: String?
    var text: String?
    var status: String
    var data: [String: Any] = [:]
    var delta = ""
    var output: CodexCommandOutput? = nil
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
        let text = type == "commandExecution" ? data["aggregatedOutput"] as? String : data["text"] as? String
        let keepsStreamedText = text == nil && (type == "agentMessage" || type == "commandExecution")
        let previous = existing.map { items[$0] }
        let item = CodexItem(id: id, type: type, phase: data["phase"] as? String,
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

enum CodexRequestOutcome: Equatable {
    case accepted, declined, answered, resolved, unanswered
}

struct CodexRequest: Identifiable {
    let rpcID: Any
    let method: String
    let params: [String: Any]
    var outcome: CodexRequestOutcome? = nil
    var isApproval: Bool { method != "item/tool/requestUserInput" }
    var id: String { CodexJSON.pretty(rpcID) }
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
