import Foundation

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
