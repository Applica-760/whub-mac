import Foundation

enum ClaudeCodeMapping {
    static func input(_ input: [AgentInput], skills: [AgentSkill]) throws -> [[String: Any]] {
        var texts: [String] = []
        var selected: [AgentSkill] = []
        for item in input {
            switch item {
            case .text(let text): texts.append(text)
            case .skill(let skill):
                guard skills.contains(where: { $0.id == skill.id && $0.name == skill.name }) else {
                    throw AgentError(.invalidInput, "この接続で利用できるSkillを選び直してください。")
                }
                selected.append(skill)
            case .image:
                throw AgentError(.unsupported, "Claude Codeへの画像入力は未対応です。")
            }
        }
        guard selected.count <= 1 else { throw AgentError(.invalidInput, "Claude Codeでは1回に1つのSkillだけ指定できます。") }
        var text = texts.joined(separator: "\n")
        if let skill = selected.first {
            let mention = "(?<!\\S)\\$" + NSRegularExpression.escapedPattern(for: skill.name) + "(?![\\p{L}\\p{N}_-])"
            if let range = text.range(of: mention, options: .regularExpression) { text.removeSubrange(range) }
            text = "/" + skill.name + " " + text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [["type": "text", "text": text]]
    }

    static func output(_ item: ClaudeCodeItem) -> AgentOutput {
        if item.type == "text" {
            return .message(AgentMessage(id: item.id, role: item.isAnswer ? .answer : .progress,
                title: "進捗メッセージ", content: .markdown(item.text ?? item.delta), status: item.status))
        }
        let command = (item.input as? [String: Any])?["command"] as? String
        return .toolUse(AgentToolUse(id: item.id,
            tool: AgentTool(name: item.name == "Bash" ? command ?? item.name : item.name),
            arguments: item.input.map { .code(AgentJSON.pretty($0)) } ?? (item.delta.isEmpty ? nil : .code(item.delta)),
            result: item.result.map { [.code($0)] }, status: item.status))
    }

    static func changePreview(_ input: [String: Any]) -> String? {
        guard let path = input["file_path"] as? String else { return nil }
        if let content = input["content"] as? String { return path + "\n" + content }
        if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
            return path + "\n- " + old + "\n+ " + new
        }
        return nil
    }

    static func requestID(_ controlID: String) -> String { "request:" + controlID }

    static func request(_ params: [String: Any], controlID: String) throws -> AgentRequest {
        let id = requestID(controlID)
        let input = params["input"] as? [String: Any] ?? [:]
        let tool = params["tool_name"] as? String ?? ""
        if tool == "AskUserQuestion" {
            guard let values = input["questions"] as? [[String: Any]], !values.isEmpty else {
                throw AgentError(.adapterFailed, "質問の形式が不正です。")
            }
            var seen = Set<String>()
            let questions = try values.map { value -> AgentQuestion in
                guard let prompt = value["question"] as? String, !prompt.isEmpty, seen.insert(prompt).inserted else {
                    throw AgentError(.adapterFailed, "質問の本文を確認できませんでした。")
                }
                let options = try (value["options"] as? [[String: Any]] ?? []).map { option -> AgentQuestion.Option in
                    guard let label = option["label"] as? String else {
                        throw AgentError(.adapterFailed, "質問の選択肢が不正です。")
                    }
                    return AgentQuestion.Option(label: label, description: option["description"] as? String ?? "")
                }
                return AgentQuestion(id: prompt, prompt: prompt, options: options, isSecret: false,
                                     isMultiSelect: value["multiSelect"] as? Bool ?? false)
            }
            return AgentRequest(id: id, kind: .questions(questions))
        }
        let name = params["display_name"] as? String ?? tool
        return AgentRequest(id: id, kind: .approval(AgentApprovalRequest(
            reason: [name, params["description"] as? String].compactMap { $0 }.joined(separator: " · "),
            command: input["command"] as? String, directory: nil, changePreview: changePreview(input),
            permissionsDescription: nil, details: AgentJSON.pretty(input))))
    }

    static func response(_ response: AgentResponse, to request: AgentRequest,
                         input: [String: Any]) throws -> (result: [String: Any], outcome: AgentRequestOutcome) {
        switch (request.kind, response) {
        case (.approval, .approval(let allow)):
            let result: [String: Any] = allow ? ["behavior": "allow", "updatedInput": input]
                : ["behavior": "deny", "message": "The user denied this request."]
            return (result, allow ? .accepted : .declined)
        case (.questions(let questions), .answers(let answers)):
            guard questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AgentError(.invalidInput, "すべての質問に回答してください。")
            }
            var updated = input
            updated["answers"] = Dictionary(uniqueKeysWithValues: questions.map { ($0.prompt, answers[$0.id]!) })
            return (["behavior": "allow", "updatedInput": updated], .answered)
        default:
            throw AgentError(.invalidInput, "要求に対応する種類の回答を指定してください。")
        }
    }

    static func text(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
