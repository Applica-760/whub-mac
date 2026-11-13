import Foundation

struct ClaudeCodeModel: Identifiable {
    let id: String
    let options: [AgentModelOption]

    init(_ data: [String: Any]) throws {
        guard let value = data["value"] as? String, !value.isEmpty,
              let displayName = data["displayName"] as? String else {
            throw AgentError(.adapterFailed, "モデル一覧の形式が不正です。")
        }
        let description = data["description"] as? String ?? ""
        let efforts: [String?] = data["supportsEffort"] as? Bool == true ? data["supportedEffortLevels"] as? [String] ?? [] : []
        id = value
        options = ([nil] + efforts).map { effort in
            AgentModelOption(id: AgentJSON.pretty([value, effort as Any? ?? NSNull()]), modelID: value,
                             displayName: displayName, description: description,
                             effort: effort, isDefaultEffort: effort == nil)
        }
    }
}

struct ClaudeCodeItem: Identifiable {
    let id: String
    let messageID: String
    let type: String
    var name = ""
    var text: String?
    var delta = ""
    var input: Any?
    var result: String?
    var status = AgentExecutionStatus.running
    var isAnswer = false
}

struct ClaudeCodeTurn: Identifiable {
    let id = UUID()
    var messageID: String?
    var blocks: [Int: String] = [:]
    var items: [ClaudeCodeItem] = []

    mutating func stream(_ event: [String: Any]) -> String? {
        switch event["type"] as? String {
        case "message_start":
            messageID = (event["message"] as? [String: Any])?["id"] as? String
            blocks.removeAll()
            return nil
        case "content_block_start":
            guard let messageID, let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any],
                  let type = block["type"] as? String, ["text", "tool_use"].contains(type) else { return nil }
            let id = type == "tool_use" ? block["id"] as? String ?? "\(messageID):\(index)" : "\(messageID):\(index)"
            blocks[index] = id
            if !items.contains(where: { $0.id == id }) {
                items.append(ClaudeCodeItem(id: id, messageID: messageID, type: type, name: block["name"] as? String ?? ""))
            }
            return id
        case "content_block_delta":
            guard let index = event["index"] as? Int, let id = blocks[index],
                  let delta = event["delta"] as? [String: Any],
                  let text = delta["text"] as? String ?? delta["partial_json"] as? String,
                  let item = items.firstIndex(where: { $0.id == id }) else { return nil }
            items[item].delta += text
            return id
        default:
            return nil
        }
    }

    mutating func complete(_ message: [String: Any]) -> [String] {
        guard let messageID = message["id"] as? String, let content = message["content"] as? [[String: Any]] else { return [] }
        var completed: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                let id = items.last(where: { $0.messageID == messageID && $0.type == "text" && $0.status == .running })?.id
                    ?? "\(messageID):\(items.count)"
                update(id, messageID: messageID, type: "text") {
                    $0.text = block["text"] as? String ?? ""
                    $0.status = .completed
                }
                completed.append(id)
            case "tool_use":
                guard let id = block["id"] as? String else { continue }
                update(id, messageID: messageID, type: "tool_use") {
                    $0.name = block["name"] as? String ?? $0.name
                    $0.input = block["input"]
                }
                completed.append(id)
            default: break
            }
        }
        return completed
    }

    mutating func completeTool(_ block: [String: Any]) -> String? {
        guard let id = block["tool_use_id"] as? String, let item = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[item].result = ClaudeCodeMapping.text(block["content"])
        items[item].status = block["is_error"] as? Bool == true ? .failed : .completed
        return id
    }

    mutating func inferFinalAnswerIfNeeded() {
        if !items.contains(where: \.isAnswer), let last = items.lastIndex(where: { $0.type == "text" }) {
            items[last].isAnswer = true
        }
    }

    private mutating func update(_ id: String, messageID: String, type: String, _ change: (inout ClaudeCodeItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) { change(&items[index]) }
        else {
            var item = ClaudeCodeItem(id: id, messageID: messageID, type: type)
            change(&item)
            items.append(item)
        }
    }
}
