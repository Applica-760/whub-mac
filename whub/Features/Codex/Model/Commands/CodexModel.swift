import Foundation

struct CodexModel: Identifiable {
    struct Effort: Identifiable {
        let reasoningEffort: String
        let description: String
        var id: String { reasoningEffort }
    }

    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultEffort: String
    let efforts: [Effort]
    let supportsImages: Bool
    let isDefault: Bool

    init(_ data: [String: Any]) throws {
        guard let id = data["id"] as? String, !id.isEmpty,
              let model = data["model"] as? String, !model.isEmpty,
              let displayName = data["displayName"] as? String,
              let defaultEffort = data["defaultReasoningEffort"] as? String,
              let options = data["supportedReasoningEfforts"] as? [[String: Any]] else {
            throw CodexError(message: "モデル一覧の形式が不正です。")
        }
        self.id = id
        isDefault = data["isDefault"] as? Bool ?? false
        self.model = model
        self.displayName = displayName
        description = data["description"] as? String ?? ""
        self.defaultEffort = defaultEffort
        let parsed = try options.map { option -> Effort in
            guard let effort = option["reasoningEffort"] as? String, !effort.isEmpty else {
                throw CodexError(message: "推論設定の形式が不正です。")
            }
            return Effort(reasoningEffort: effort, description: option["description"] as? String ?? "")
        }
        efforts = parsed.isEmpty ? [Effort(reasoningEffort: defaultEffort, description: "")] : parsed
        guard efforts.contains(where: { $0.reasoningEffort == defaultEffort }),
              Set(efforts.map(\.id)).count == efforts.count else {
            throw CodexError(message: "モデルの既定推論設定を確認できませんでした。")
        }
        supportsImages = (data["inputModalities"] as? [String] ?? ["text", "image"]).contains("image")
    }

    func parameters(threadID: String, effort: String) -> [String: Any] {
        ["threadId": threadID, "model": model, "effort": effort]
    }
}
