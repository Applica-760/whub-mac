import AppKit
import Foundation

enum CodexAgentMapping {
    static func input(_ input: [AgentInput], skills: [AgentSkill]) throws -> [[String: Any]] {
        try input.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": text]
            case .skill(let skill):
                guard skills.contains(where: { $0.id == skill.id && $0.name == skill.name }) else {
                    throw CodexError(message: "この接続で利用できるSkillを選び直してください。")
                }
                return ["type": "skill", "name": skill.name, "path": skill.id]
            case .image(let attachment):
                guard let tiff = attachment.image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw CodexError(message: "画像を送信用のPNGへ変換できませんでした。")
                }
                return ["type": "image", "url": "data:image/png;base64," + png.base64EncodedString()]
            case .slashCommand:
                throw CodexError(message: "コマンドは会話入力と分けて実行してください。")
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

    static func output(_ item: CodexItem) -> AgentOutput {
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
            result = .code(CodexJSON.pretty(item.data))
        case "plan":
            name = "計画"
            result = .markdown(item.text == nil && item.delta.isEmpty ? CodexJSON.pretty(item.data) : text)
        case "contextCompaction":
            name = "会話を圧縮"
            result = .code(CodexJSON.pretty(item.data))
        default:
            name = item.data["tool"] as? String ?? item.type
            result = .code(CodexJSON.pretty(item.data))
        }
        return .toolUse(AgentToolUse(id: item.id,
            tool: AgentTool(name: name, source: item.data["server"] as? String),
            arguments: item.data["arguments"].map { .code(CodexJSON.pretty($0)) },
            result: [result], status: status(item.status)))
    }

    static func changePreview(_ changes: [[String: Any]]) -> String {
        changes.map { ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "") }
            .joined(separator: "\n\n")
    }

    static func requestID(_ rpcID: Any) -> String { "request:" + CodexJSON.pretty(rpcID) }

    static func request(method: String, params: [String: Any], rpcID: Any) throws -> AgentRequest {
        let id = requestID(rpcID)
        if method == "item/tool/requestUserInput" {
            guard let values = params["questions"] as? [[String: Any]], !values.isEmpty else {
                throw CodexError(message: "質問の形式が不正です。")
            }
            var seen = Set<String>()
            let questions = try values.map { value -> AgentQuestion in
                guard let id = value["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                      let prompt = value["question"] as? String else {
                    throw CodexError(message: "質問の識別子または本文を確認できませんでした。")
                }
                let options = try (value["options"] as? [[String: Any]] ?? []).map { option -> AgentQuestion.Option in
                    guard let label = option["label"] as? String else {
                        throw CodexError(message: "質問の選択肢が不正です。")
                    }
                    return AgentQuestion.Option(label: label, description: option["description"] as? String ?? "")
                }
                return AgentQuestion(id: id, prompt: prompt, options: options, isSecret: value["isSecret"] as? Bool ?? false)
            }
            return AgentRequest(id: id, kind: .questions(questions))
        }
        guard ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
               "item/permissions/requestApproval"].contains(method) else {
            throw CodexError(message: "未対応の要求です: \(method)")
        }
        return AgentRequest(id: id, kind: .approval(AgentApprovalRequest(
            reason: params["reason"] as? String, command: params["command"] as? String,
            directory: params["cwd"] as? String,
            changePreview: (params["changes"] as? [[String: Any]]).map { changePreview($0) } ?? params["changePreview"] as? String,
            permissionsDescription: params["permissions"].map(CodexJSON.pretty), details: CodexJSON.pretty(params))))
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
                throw CodexError(message: "すべての質問に回答してください。")
            }
            let payload = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, ["answers": [answers[$0.id]!]]) })
            return (["answers": payload], .answered)
        default:
            throw CodexError(message: "要求に対応する種類の回答を指定してください。")
        }
    }

    static func modelOptions(_ model: CodexModel) -> [AgentModelOption] {
        model.efforts.map { effort in
            AgentModelOption(id: CodexJSON.pretty([model.id, effort.reasoningEffort]), modelID: model.model,
                displayName: model.displayName, description: effort.description.isEmpty ? model.description : effort.description,
                effort: effort.reasoningEffort, isDefaultEffort: effort.reasoningEffort == model.defaultEffort)
        }
    }

    static func historyEntry(_ value: [String: Any]) throws -> AgentHistoryEntry {
        let thread = try CodexRecentThread(value)
        return AgentHistoryEntry(id: thread.id, name: thread.name, preview: thread.preview,
                                 directory: thread.directory, updatedAt: thread.updatedAt)
    }

    static func exchanges(_ values: [[String: Any]]) throws -> [AgentExchange] {
        try values.map { value in
            guard let id = value["id"] as? String, !id.isEmpty,
                  let execution = value["status"] as? String, ["completed", "failed", "interrupted"].contains(execution),
                  (value["itemsView"] as? String ?? "full") == "full",
                  let items = value["items"] as? [[String: Any]] else {
                throw CodexError(message: "履歴が不完全か、会話が実行中です。")
            }
            var input: [AgentInput] = []
            var additionalInputs: [AgentAdditionalInput] = []
            var hasInput = false
            var turn = CodexTurn(remoteID: id, prompt: "")
            for item in items {
                guard item["id"] is String, item["type"] is String else {
                    throw CodexError(message: "会話履歴の項目が不正です。")
                }
                if item["type"] as? String == "userMessage" {
                    guard let contents = item["content"] as? [[String: Any]] else {
                        throw CodexError(message: "会話の入力履歴が不正です。")
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
               let data = Data(base64Encoded: String(url[separator.upperBound...])), let image = NSImage(data: data) {
                return .image(AgentImageAttachment(image: image))
            }
        default: break
        }
        // 未合意のmention等を別の入力型に置き換えたり、履歴から欠落させない。
        throw CodexError(message: "共通入力への変換が未対応の履歴です: \(value["type"] as? String ?? "不明")")
    }
}

// 既存Statusの項目順・残量表記を維持する。
extension CodexAgentMapping {
    static func statusText(_ snapshot: CodexStatusSnapshot, timeZone: TimeZone = .current) -> String {
        let directory = snapshot.directory
        let threadID = snapshot.threadID
        let settings = snapshot.settings
        let config = snapshot.config
        let account = snapshot.account
        let limits = snapshot.limits
        let tokenUsage = snapshot.tokenUsage
        let failures = snapshot.failures.map { failure in
            switch failure {
            case .settings: "Settings"
            case .account: "Account"
            case .rateLimits: "Rate limits"
            }
        }
        var rows: [(String, String)] = []
        func value(_ source: [String: Any]?, _ key: String) -> String? {
            guard let text = source?[key] as? String, !text.isEmpty else { return nil }
            return text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        let active = threadID != nil
        let model = active ? value(settings, "model") : value(config, "model")
        let effort = active ? value(settings, "effort") : value(config, "model_reasoning_effort")
        rows.append(("Model", (model ?? "Not available") + (effort.map { " (reasoning \($0))" } ?? "")))
        if let provider = active ? value(settings, "modelProvider") : value(config, "model_provider") {
            rows.append(("Model provider", provider))
        }
        rows.append(("Directory", directory))
        let sandbox = active ? value(settings["sandboxPolicy"] as? [String: Any], "type") : value(config, "sandbox_mode")
        let policy = active ? value(settings, "approvalPolicy") : value(config, "approval_policy")
        let reviewer = active ? value(settings, "approvalsReviewer") : value(config, "approvals_reviewer")
        rows.append(("Permissions", [sandbox, policy, reviewer].compactMap { $0 }.joined(separator: " · ").codexAgentNonEmpty ?? "Not available"))
        if let sources = settings["instructionSources"] as? [String] {
            rows.append(("Agents.md", sources.isEmpty ? "<none>" : sources.joined(separator: ", ")))
        }
        if let tier = active ? value(settings, "serviceTier") : value(config, "service_tier") {
            rows.append(("Service tier", tier))
        }
        switch account?["type"] as? String {
        case "apiKey": rows.append(("Account", "API key configured"))
        case "chatgpt":
            rows.append(("Account", [value(account, "email"), value(account, "planType")].compactMap { $0 }.joined(separator: " · ").codexAgentNonEmpty ?? "ChatGPT"))
        default: rows.append(("Account", failures.contains("Account") ? "Unavailable" : "Not signed in"))
        }
        rows.append(("Session", threadID ?? "Not started"))
        if !active { rows.append(("Settings", "Configured defaults; session not started")) }
        if let last = tokenUsage?["last"] as? [String: Any],
           let used = (last["totalTokens"] as? NSNumber)?.doubleValue,
           let window = (tokenUsage?["modelContextWindow"] as? NSNumber)?.doubleValue, window > 0, used.isFinite, window.isFinite {
            let remaining = max(0, min(100, (1 - used / window) * 100))
            rows.append(("Context window", "\(Int(remaining))% left (\(used.formatted(.number.precision(.fractionLength(0)))) used / \(window.formatted(.number.precision(.fractionLength(0)))))"))
        }
        if account?["type"] as? String == "apiKey" {
            rows.append(("Rate limits", "Not available for API key authentication"))
        } else if let limits {
            let buckets = limits["rateLimitsByLimitId"] as? [String: [String: Any]]
            let snapshots: [(String, [String: Any])] = buckets?.sorted { $0.key < $1.key }
                ?? (limits["rateLimits"] as? [String: Any]).map { [("", $0)] } ?? []
            for (id, snapshot) in snapshots {
                for key in ["primary", "secondary"] {
                    guard let window = snapshot[key] as? [String: Any],
                          let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite,
                          let minutes = window["windowDurationMins"] as? Int, minutes > 0 else { continue }
                    let label = minutes == 10080 ? "Weekly limit" : minutes % 60 == 0 ? "\(minutes / 60)h limit" : "\(minutes)m limit"
                    let remaining = max(0, min(100, 100 - used))
                    let filled = Int(remaining / 5)
                    var text = "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled) + "] \(Int(remaining))% left"
                    if let resets = (window["resetsAt"] as? NSNumber)?.doubleValue, resets.isFinite {
                        let formatter = DateFormatter()
                        formatter.timeZone = timeZone
                        formatter.dateFormat = "MM/dd HH:mm z"
                        text += " (resets \(formatter.string(from: Date(timeIntervalSince1970: resets))))"
                    }
                    rows.append(((snapshots.count > 1 ? (value(snapshot, "limitName") ?? id) + " · " : "") + label, text))
                }
                if let credits = snapshot["credits"] as? [String: Any] {
                    if credits["unlimited"] as? Bool == true { rows.append(("Credits", "Unlimited")) }
                    else if let balance = value(credits, "balance") { rows.append(("Credits", balance)) }
                    else if let available = credits["hasCredits"] as? Bool { rows.append(("Credits", available ? "Available" : "Unavailable")) }
                }
            }
            if !rows.contains(where: { $0.0.contains("limit") }) { rows.append(("Rate limits", "Not available")) }
        } else {
            rows.append(("Rate limits", "Not available"))
        }
        for field in failures { rows.append((field, "Unable to retrieve")) }
        let width = rows.map { $0.0.count }.max() ?? 0
        return rows.map { $0.0 + ":" + String(repeating: " ", count: width - $0.0.count + 2) + $0.1 }.joined(separator: "\n")
    }
}

private extension String {
    var codexAgentNonEmpty: String? { isEmpty ? nil : self }
}
