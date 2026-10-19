import Foundation

enum CodexMapping {
    static func input(_ input: [AgentInput], skills: [AgentSkill]) throws -> [[String: Any]] {
        try input.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": text]
            case .skill(let skill):
                guard skills.contains(where: { $0.id == skill.id && $0.name == skill.name }) else {
                    throw CodexAgentError(message: "この接続で利用できるSkillを選び直してください。")
                }
                return ["type": "skill", "name": skill.name, "path": skill.id]
            case .image(let attachment):
                return ["type": "image", "url": "data:" + attachment.mediaType + ";base64," + attachment.data.base64EncodedString()]
            }
        }
    }

    static func status(_ value: String) -> AgentExecutionStatus {
        switch value {
        case "inProgress", "running": .running
        case "completed": .completed
        case "interrupted": .interrupted
        default: .failed
        }
    }

    static func output(_ item: CodexAgentItem) -> AgentOutput {
        let text = (item.text ?? "") + item.delta
        if item.type == "agentMessage" {
            return .message(AgentMessage(id: item.id,
                role: item.phase == "final_answer" ? .answer : .progress,
                title: "進捗メッセージ", content: .markdown(text), status: status(item.status)))
        }
        let name: String
        let result: AgentContent
        switch item.type {
        case "commandExecution":
            name = item.data["command"] as? String ?? "コマンド実行"
            result = .code(text)
        case "fileChange":
            name = "ファイル変更"
            result = .code(changePreview(item.data["changes"] as? [[String: Any]] ?? []))
        case "webSearch":
            name = "Web検索 · " + (item.data["query"] as? String ?? "")
            result = .code(CodexAgentJSON.pretty(item.data))
        case "plan":
            name = "計画"
            result = .markdown(item.text == nil && item.delta.isEmpty ? CodexAgentJSON.pretty(item.data) : text)
        case "contextCompaction":
            name = "会話を圧縮"
            result = .code(CodexAgentJSON.pretty(item.data))
        default:
            name = item.data["tool"] as? String ?? item.type
            result = .code(CodexAgentJSON.pretty(item.data))
        }
        return .toolUse(AgentToolUse(id: item.id,
            tool: AgentTool(name: name, source: item.data["server"] as? String),
            arguments: item.data["arguments"].map { .code(CodexAgentJSON.pretty($0)) },
            result: [result], status: status(item.status)))
    }

    static func changePreview(_ changes: [[String: Any]]) -> String {
        changes.map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }
            .joined(separator: "\n\n")
    }

    static func requestID(_ rpcID: Any) -> String { "request:" + CodexAgentJSON.pretty(rpcID) }

    static func request(method: String, params: [String: Any], rpcID: Any) throws -> AgentRequest {
        let id = requestID(rpcID)
        if method == "item/tool/requestUserInput" {
            guard let values = params["questions"] as? [[String: Any]], !values.isEmpty else {
                throw CodexAgentError(message: "質問の形式が不正です。")
            }
            var seen = Set<String>()
            let questions = try values.map { value -> AgentQuestion in
                guard let id = value["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                      let prompt = value["question"] as? String else {
                    throw CodexAgentError(message: "質問の識別子または本文を確認できませんでした。")
                }
                let options = try (value["options"] as? [[String: Any]] ?? []).map { option -> AgentQuestion.Option in
                    guard let label = option["label"] as? String else {
                        throw CodexAgentError(message: "質問の選択肢が不正です。")
                    }
                    return AgentQuestion.Option(label: label, description: option["description"] as? String ?? "")
                }
                return AgentQuestion(id: id, prompt: prompt, options: options, isSecret: value["isSecret"] as? Bool ?? false)
            }
            return AgentRequest(id: id, kind: .questions(questions))
        }
        guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
               "item/permissions/requestApproval"].contains(method) else {
            throw CodexAgentError(message: "未対応の要求です: \(method)")
        }
        return AgentRequest(id: id, kind: .approval(AgentApprovalRequest(
            reason: params["reason"] as? String, command: params["command"] as? String,
            directory: params["cwd"] as? String,
            changePreview: (params["changes"] as? [[String: Any]]).map { changePreview($0) } ?? params["changePreview"] as? String,
            permissionsDescription: params["permissions"].map(CodexAgentJSON.pretty), details: CodexAgentJSON.pretty(params))))
    }

    static func response(_ response: AgentResponse, to request: AgentRequest,
                         method: String, params: [String: Any]) throws -> (result: [String: Any], outcome: AgentRequestOutcome) {
        switch (request.kind, response) {
        case (.approval, .approval(let allow)):
            let result: [String: Any] = method == "item/permissions/requestApproval"
                ? ["permissions": allow ? (params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"]
                : ["decision": allow ? "accept" : "decline"]
            return (result, allow ? .accepted : .declined)
        case (.questions(let questions), .answers(let answers)):
            guard questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CodexAgentError(message: "すべての質問に回答してください。")
            }
            let payload = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, ["answers": [answers[$0.id]!]]) })
            return (["answers": payload], .answered)
        default:
            throw CodexAgentError(message: "要求に対応する種類の回答を指定してください。")
        }
    }

    static func historyEntry(_ value: [String: Any]) throws -> AgentHistoryEntry {
        guard let id = value["id"] as? String, !id.isEmpty,
              let directory = value["cwd"] as? String, directory.hasPrefix("/"),
              let updatedAt = value["updatedAt"] as? Double else {
            throw CodexAgentError(message: "会話一覧の形式が不正です。")
        }
        return AgentHistoryEntry(id: id, name: value["name"] as? String, preview: value["preview"] as? String,
                                 directory: directory, updatedAt: Date(timeIntervalSince1970: updatedAt))
    }

    static func exchanges(_ values: [[String: Any]]) throws -> [AgentExchange] {
        try values.map { value in
            guard let id = value["id"] as? String, !id.isEmpty,
                  let execution = value["status"] as? String, ["completed", "failed", "interrupted"].contains(execution),
                  (value["itemsView"] as? String ?? "full") == "full",
                  let items = value["items"] as? [[String: Any]] else {
                throw CodexAgentError(message: "履歴が不完全か、会話が実行中です。")
            }
            var input: [AgentInput] = []
            var additionalInputs: [AgentAdditionalInput] = []
            var hasInput = false
            var turn = CodexAgentTurn(remoteID: id)
            for item in items {
                guard item["id"] is String, item["type"] is String else {
                    throw CodexAgentError(message: "会話履歴の項目が不正です。")
                }
                if item["type"] as? String == "userMessage" {
                    guard let contents = item["content"] as? [[String: Any]] else {
                        throw CodexAgentError(message: "会話の入力履歴が不正です。")
                    }
                    let message = try contents.map { try historyInput($0) }
                    if hasInput {
                        additionalInputs.append(AgentAdditionalInput(input: message, outputIndex: turn.items.count))
                    } else {
                        input = message
                        hasInput = true
                    }
                }
                turn.updateItem(item, completed: true)
            }
            turn.inferFinalAnswerIfNeeded()
            var exchange = AgentExchange(input: input)
            exchange.additionalInputs = additionalInputs
            exchange.outputs = turn.items.map { output($0) }
            exchange.status = status(execution)
            return exchange
        }
    }

    private static func historyInput(_ value: [String: Any]) throws -> AgentInput {
        switch value["type"] as? String {
        case "text":
            if let text = value["text"] as? String { return .text(text) }
        case "skill":
            if let name = value["name"] as? String, let path = value["path"] as? String {
                return .skill(AgentSkill(id: path, name: name, description: ""))
            }
        case "image":
            if let url = value["url"] as? String, url.hasPrefix("data:image/"),
               let separator = url.range(of: ";base64,"),
               let data = Data(base64Encoded: String(url[separator.upperBound...])) {
                return .image(try AgentImageAttachment(data: data, mediaType: String(url[url.index(url.startIndex, offsetBy: 5)..<separator.lowerBound])))
            }
        default: break
        }
        // 未合意のmention等を別の入力型に置き換えたり、履歴から欠落させない。
        throw CodexAgentError(message: "共通入力への変換が未対応の履歴です: \(value["type"] as? String ?? "不明")")
    }
}
