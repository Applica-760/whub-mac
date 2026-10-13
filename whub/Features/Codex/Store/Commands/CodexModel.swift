import Foundation

extension CodexCommandsStore {
    func loadModels(directory: String) async {
        guard !isLoadingModels else { return }
        let generation = generationID
        isLoadingModels = true
        modelError = nil
        defer { if generation == generationID { isLoadingModels = false } }
        do {
            var loaded: [CodexModel] = []
            var cursor: String?
            var cursors = Set<String>()
            var ids = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100, "includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let result = try await request("model/list", params, directory)
                guard generation == generationID else { return }
                guard let data = result["data"] as? [[String: Any]] else {
                    throw CodexError(message: "モデル一覧を読み込めませんでした。")
                }
                for entry in data where entry["hidden"] as? Bool != true {
                    let model = try CodexModel(entry)
                    if ids.insert(model.id).inserted { loaded.append(model) }
                }
                cursor = result["nextCursor"] as? String
                if let cursor, !cursors.insert(cursor).inserted {
                    throw CodexError(message: "モデル一覧の取得位置が進みませんでした。")
                }
            } while cursor != nil
            models = loaded
        } catch {
            if generation == generationID { modelError = error.localizedDescription }
        }
    }

    func applyModel(_ model: CodexModel, effort: String, session: CodexStore) async -> Bool {
        modelError = nil
        do {
            try await session.changeModel(model, effort: effort)
            return true
        } catch {
            modelError = error.localizedDescription
            return false
        }
    }
}
