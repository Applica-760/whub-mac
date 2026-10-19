import Foundation

@MainActor
final class CodexAdapter: AgentAdapter {
    let kind = AgentKind.codex
    let events: AsyncStream<AgentEvent>
    private let emitter: AsyncStream<AgentEvent>.Continuation
    private let client: CodexClient
    private let requestOverride: (@MainActor (String, [String: Any], String) async throws -> [String: Any])?
    private let responseOverride: (@MainActor (Any, [String: Any]) throws -> Void)?
    private var directory: String?
    private var isClosed = false
    private var threadID: String?
    private var turn: CodexAgentTurn?
    private var stopRequested = false
    private var needsResume = false
    private var isPreparingThread = false
    private var models: [CodexAgentModel] = []
    private var skills: [AgentSkill] = []
    private var settings: [String: Any] = [:]
    private var tokenUsage: [String: Any]?
    private var pendingRequests: [String: PendingRequest] = [:]

    private struct PendingRequest {
        let rpcID: Any
        let method: String
        let params: [String: Any]
        var request: AgentRequest
    }

    init(client: CodexClient? = nil,
         request: (@MainActor (String, [String: Any], String) async throws -> [String: Any])? = nil,
         respond: (@MainActor (Any, [String: Any]) throws -> Void)? = nil) {
        let client = client ?? CodexClient()
        self.client = client
        requestOverride = request
        responseOverride = respond
        let stream = AsyncStream<AgentEvent>.makeStream()
        events = stream.stream
        emitter = stream.continuation
        client.onEvent = { [weak self] in self?.receive($0, params: $1, requestID: $2) }
        client.onDisconnect = { [weak self] message in
            guard let self, !self.isClosed else { return }
            self.needsResume = self.threadID != nil
            self.finish(.failed(message))
        }
    }

    func connect(directory: String) async throws {
        guard !isClosed else { throw CancellationError() }
        try validateDirectory(directory)
        guard self.directory == nil || self.directory == directory else {
            throw CodexAgentError(message: "接続済みSessionの作業ディレクトリは変更できません。")
        }
        self.directory = directory
        if requestOverride == nil { try await client.connect(directory: directory) }
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
    }

    func send(_ input: [AgentInput]) async throws {
        guard turn == nil else { throw CodexAgentError(message: "会話は実行中です。追加送信を使用してください。") }
        let payload = try inputPayload(input)
        let active = CodexAgentTurn()
        turn = active
        stopRequested = false
        do {
            try await prepareThread()
            guard turn?.id == active.id else { throw CancellationError() }
            if stopRequested { finish(.interrupted); return }
            guard let threadID else { throw CodexAgentError(message: "会話IDを確認できませんでした。") }
            let result = try await rpc("turn/start", ["threadId": threadID, "input": payload])
            guard turn?.id == active.id else { return }
            guard let remote = result["turn"] as? [String: Any], let id = remote["id"] as? String, !id.isEmpty else {
                throw CodexAgentError(message: "Codexから実行IDを取得できませんでした。")
            }
            guard turn?.remoteID == nil || turn?.remoteID == id else {
                throw CodexAgentError(message: "開始した実行のIDが一致しません。")
            }
            turn?.remoteID = id
            if stopRequested { try await interrupt() }
        } catch {
            if turn?.id == active.id {
                for id in Array(pendingRequests.keys) { resolve(id, outcome: .unanswered) }
                turn = nil
                stopRequested = false
            }
            throw error
        }
    }

    func sendAdditionalInput(_ input: [AgentInput]) async throws {
        guard !stopRequested, !needsResume, let threadID, let active = turn, let turnID = active.remoteID else {
            throw CodexAgentError(message: "追加送信できる実行がありません。")
        }
        let result = try await rpc("turn/steer", ["threadId": threadID, "input": try inputPayload(input), "expectedTurnId": turnID])
        guard result["turnId"] as? String == turnID else {
            throw CodexAgentError(message: "追加送信の対象を確認できませんでした。")
        }
    }

    func interrupt() async throws {
        guard let active = turn else { return }
        stopRequested = true
        guard let threadID, let turnID = active.remoteID else { return }
        for attempt in 0..<10 {
            guard turn?.id == active.id else { return }
            do {
                _ = try await rpc("turn/interrupt", ["threadId": threadID, "turnId": turnID])
                return
            } catch {
                guard turn?.id == active.id else { return }
                if error.localizedDescription == "no active turn to interrupt", attempt < 9 {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                stopRequested = false
                throw error
            }
        }
    }

    func loadModelOptions() async throws -> [AgentModelOption] {
        let result = try await pages("model/list", params: ["limit": 100, "includeHidden": false])
        var seen = Set<String>()
        let loaded = try result.filter { $0["hidden"] as? Bool != true }.map(CodexAgentModel.init)
            .filter { seen.insert($0.id).inserted }
        let config = try await rpc("config/read", ["includeLayers": false, "cwd": directory ?? ""])
        guard let values = config["config"] as? [String: Any],
              let model = values["model"] as? String ?? loaded.first(where: \.isDefault)?.options.first?.modelID else {
            throw CodexAgentError(message: "起動時のモデル設定を取得できませんでした。")
        }
        models = loaded
        if threadID == nil {
            settings["model"] = model
            settings["effort"] = values["model_reasoning_effort"] as? String
                ?? loaded.flatMap(\.options).first(where: { $0.modelID == model && $0.isDefaultEffort })?.effort
        }
        publishModelOption()
        return loaded.flatMap(\.options)
    }

    func loadSkills() async throws -> [AgentSkill] {
        let result = try await rpc("skills/list", ["cwds": [directory ?? ""], "forceReload": true])
        guard let entries = result["data"] as? [[String: Any]] else {
            throw CodexAgentError(message: "Skill一覧の形式が不正です。")
        }
        let errors = entries.flatMap { $0["errors"] as? [[String: Any]] ?? [] }
        guard errors.isEmpty else { throw CodexAgentError(message: CodexAgentJSON.pretty(errors)) }
        var seen = Set<String>()
        let loaded = try entries.flatMap { entry -> [AgentSkill] in
            guard let values = entry["skills"] as? [[String: Any]] else {
                throw CodexAgentError(message: "Skill一覧の形式が不正です。")
            }
            return try values.filter { $0["enabled"] as? Bool != false }.map { value in
                guard let path = value["path"] as? String, !path.isEmpty, let name = value["name"] as? String else {
                    throw CodexAgentError(message: "Skillの識別子を確認できませんでした。")
                }
                return AgentSkill(id: path, name: name, description: value["description"] as? String ?? "")
            }
        }.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        skills = loaded
        return loaded
    }

    func loadStatus() async throws -> [AgentContent] {
        guard !isClosed, let directory else { throw CodexAgentError(message: "Codexに接続されていません。") }
        let activeID = threadID
        let activeSettings = settings
        let usage = tokenUsage
        var config: [String: Any]?
        var account: [String: Any]?
        var limits: [String: Any]?
        var failures: [CodexAgentStatusFailure] = []
        do {
            let result = try await rpc("config/read", ["includeLayers": false, "cwd": directory])
            config = result["config"] as? [String: Any]
            if config == nil { failures.append(.settings) }
        } catch { failures.append(.settings) }
        do {
            let result = try await rpc("account/read", ["refreshToken": false])
            account = result["account"] as? [String: Any]
            if result["account"] == nil || (result["account"] is NSNull == false && account == nil) { failures.append(.account) }
        } catch { failures.append(.account) }
        if account?["type"] as? String == "chatgpt" {
            do { limits = try await rpc("account/rateLimits/read") }
            catch { failures.append(.rateLimits) }
        }
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        return [.code(CodexMapping.statusText(CodexAgentStatusSnapshot(directory: directory, threadID: activeID,
            settings: activeSettings, config: config, account: account, limits: limits, tokenUsage: usage, failures: failures)))]
    }

    func changeModel(_ option: AgentModelOption) async throws {
        guard turn == nil,
              let selected = models.flatMap(\.options).first(where: { $0.id == option.id }),
              let effort = selected.effort else {
            throw CodexAgentError(message: "現在選択できるモデルとEffortを指定してください。")
        }
        try await prepareThread()
        guard let threadID else { throw CodexAgentError(message: "会話IDを確認できませんでした。") }
        _ = try await rpc("thread/settings/update", ["threadId": threadID, "model": selected.modelID, "effort": effort])
        settings["model"] = selected.modelID
        settings["effort"] = effort
        publishModelOption()
    }

    func respond(to requestID: String, with response: AgentResponse) async throws {
        guard !isClosed, let pending = pendingRequests[requestID] else {
            throw CodexAgentError(message: "未回答の要求を確認できませんでした。")
        }
        let mapped = try CodexMapping.response(response, to: pending.request, method: pending.method, params: pending.params)
        if let responseOverride { try responseOverride(pending.rpcID, mapped.result) }
        else { try client.respond(id: pending.rpcID, result: mapped.result) }
        resolve(requestID, outcome: mapped.outcome)
    }

    func loadHistory(cursor: String?) async throws -> AgentHistoryPage {
        var params: [String: Any] = ["limit": 20, "sortKey": "updated_at", "sortDirection": "desc",
                                   "sourceKinds": ["cli", "appServer", "vscode"], "archived": false]
        if let cursor { params["cursor"] = cursor }
        let result = try await rpc("thread/list", params)
        guard let data = result["data"] as? [[String: Any]] else { throw CodexAgentError(message: "会話一覧を読み込めませんでした。") }
        return AgentHistoryPage(entries: try data.map(CodexMapping.historyEntry), nextCursor: result["nextCursor"] as? String)
    }

    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot {
        guard threadID == nil, turn == nil, directory == entry.directory else {
            throw CodexAgentError(message: "履歴は空のSessionで元の作業ディレクトリから再開してください。")
        }
        let metadata = try await rpc("thread/read", ["threadId": entry.id])
        guard let stored = metadata["thread"] as? [String: Any], stored["id"] as? String == entry.id else {
            throw CodexAgentError(message: "指定した会話を読み込めませんでした。")
        }
        var params: [String: Any] = ["threadId": entry.id]
        let paginated = stored["historyMode"] as? String == "paginated"
        if paginated { params["excludeTurns"] = true }
        let result = try await rpc("thread/resume", params)
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == entry.id,
              let cwd = result["cwd"] as? String, cwd == entry.directory,
              result["model"] is String else { throw CodexAgentError(message: "再開する会話の情報が不正です。") }
        let values: [[String: Any]]
        if paginated {
            values = try await pages("thread/turns/list", params: ["threadId": entry.id, "limit": 100,
                                                                 "sortDirection": "asc", "itemsView": "full"])
        } else {
            guard let turns = thread["turns"] as? [[String: Any]] else { throw CodexAgentError(message: "会話履歴を読み込めませんでした。") }
            values = turns
        }
        let exchanges = try CodexMapping.exchanges(values)
        threadID = entry.id
        updateSettings(result)
        needsResume = false
        emitter.yield(.conversationIDChanged(entry.id))
        return AgentHistorySnapshot(entry: entry, exchanges: exchanges, selectedModelOption: selectedOption)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingRequests.removeAll()
        turn = nil
        client.disconnect()
        emitter.finish()
    }

    private func rpc(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !isClosed, !Task.isCancelled, let directory else { throw CancellationError() }
        let result: [String: Any]
        if let requestOverride { result = try await requestOverride(method, params, directory) }
        else {
            try await client.connect(directory: directory)
            result = try await client.request(method, params)
        }
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    private func pages(_ method: String, params: [String: Any]) async throws -> [[String: Any]] {
        var values: [[String: Any]] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var params = params
            if let cursor { params["cursor"] = cursor }
            let result = try await rpc(method, params)
            guard let page = result["data"] as? [[String: Any]] else { throw CodexAgentError(message: "一覧の形式が不正です: \(method)") }
            values += page
            cursor = result["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw CodexAgentError(message: "一覧の取得位置が進みませんでした。") }
        } while cursor != nil
        return values
    }

    private func validateDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexAgentError(message: "作業フォルダが存在しません: \(directory)")
        }
    }

    private func inputPayload(_ input: [AgentInput]) throws -> [[String: Any]] {
        guard !input.isEmpty, let directory else { throw CodexAgentError(message: "入力または接続先を確認できませんでした。") }
        try validateDirectory(directory)
        if input.contains(where: { if case .image = $0 { return true }; return false }),
           models.first(where: { $0.options.contains(where: { $0.modelID == settings["model"] as? String }) })?.supportsImages == false {
            throw CodexAgentError(message: "このモデルは画像入力に対応していません。")
        }
        return try CodexMapping.input(input, skills: skills)
    }

    private func prepareThread() async throws {
        guard !isPreparingThread else { throw CodexAgentError(message: "会話の準備中です。") }
        isPreparingThread = true
        defer { isPreparingThread = false }
        if threadID == nil {
            let result = try await rpc("thread/start", ["cwd": directory ?? ""])
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String, !id.isEmpty else {
                throw CodexAgentError(message: "Codexから会話IDを取得できませんでした。")
            }
            threadID = id
            updateSettings(result)
            emitter.yield(.conversationIDChanged(id))
        } else if needsResume, let threadID {
            var params: [String: Any] = ["threadId": threadID]
            if let model = settings["model"] as? String { params["model"] = model }
            if let effort = settings["effort"] as? String { params["config"] = ["model_reasoning_effort": effort] }
            let result = try await rpc("thread/resume", params)
            guard (result["thread"] as? [String: Any])?["id"] as? String == threadID else {
                throw CodexAgentError(message: "再接続した会話IDが一致しません。")
            }
            updateSettings(result)
            needsResume = false
        }
    }

    private var selectedOption: AgentModelOption? {
        guard let model = settings["model"] as? String else { return nil }
        let effort = settings["effort"] as? String
        if let option = models.flatMap(\.options).first(where: { $0.modelID == model && $0.effort == effort }) {
            return option
        }
        return AgentModelOption(id: CodexAgentJSON.pretty([model, effort as Any? ?? NSNull()]), modelID: model,
            displayName: model, description: "", effort: effort, isDefaultEffort: false)
    }

    private func publishModelOption() {
        if let option = selectedOption { emitter.yield(.modelOptionChanged(option)) }
    }

    private func updateSettings(_ result: [String: Any]) {
        settings.merge(result.filter { ["model", "modelProvider", "effort", "reasoningEffort", "sandboxPolicy", "sandbox",
                                       "approvalPolicy", "approvalsReviewer", "serviceTier", "instructionSources"].contains($0.key) }) { _, new in new }
        if let effort = result["reasoningEffort"] { settings["effort"] = effort }
        if let sandbox = result["sandbox"] { settings["sandboxPolicy"] = sandbox }
        publishModelOption()
    }

    func receive(_ method: String, params: [String: Any], requestID: Any?) {
        guard !isClosed else { return }
        if let requestID {
            do {
                guard let active = turn, params["threadId"] == nil || params["threadId"] as? String == threadID,
                      params["turnId"] == nil || active.remoteID == nil || params["turnId"] as? String == active.remoteID else {
                    throw CodexAgentError(message: "要求の対象となる実行を確認できませんでした。")
                }
                var details = params
                if method == "item/fileChange/requestApproval", let itemID = params["itemId"] as? String,
                   let item = turn?.items.first(where: { $0.id == itemID }) { details["changes"] = item.data["changes"] }
                let request = try CodexMapping.request(method: method, params: details, rpcID: requestID)
                guard pendingRequests[request.id] == nil else { return }
                pendingRequests[request.id] = PendingRequest(rpcID: requestID, method: method, params: details, request: request)
                emitter.yield(.output(.request(request)))
            } catch {
                do { try client.rejectUnsupported(id: requestID) }
                catch { finish(.failed(error.localizedDescription)) }
            }
            return
        }
        if method == "serverRequest/resolved", let id = params["requestId"] {
            resolve(CodexMapping.requestID(id), outcome: .resolved)
            return
        }
        guard let threadID, params["threadId"] as? String == threadID else { return }
        if method == "thread/settings/updated", let settings = params["threadSettings"] as? [String: Any] {
            updateSettings(settings)
            return
        }
        if method == "thread/tokenUsage/updated" { tokenUsage = params["tokenUsage"] as? [String: Any]; return }
        guard var active = turn else { return }
        if method == "turn/started", let remote = params["turn"] as? [String: Any], let id = remote["id"] as? String {
            guard active.remoteID == nil || active.remoteID == id else { return }
            active.remoteID = id
            turn = active
            return
        }
        if let id = params["turnId"] as? String, let remoteID = active.remoteID, id != remoteID { return }
        switch method {
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            active.updateItem(item, completed: method == "item/completed")
            turn = active
            if let item = active.items.first(where: { $0.id == id }) { emitter.yield(.output(CodexMapping.output(item))) }
        case "item/agentMessage/delta", "item/commandExecution/outputDelta", "item/plan/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String,
                  let index = active.items.firstIndex(where: { $0.id == id }) else { return }
            active.items[index].delta += delta
            turn = active
            emitter.yield(.output(CodexMapping.output(active.items[index])))
        case "turn/completed":
            guard let remote = params["turn"] as? [String: Any], remote["id"] as? String == active.remoteID else { return }
            active.inferFinalAnswerIfNeeded()
            for item in active.items { emitter.yield(.output(CodexMapping.output(item))) }
            if let error = remote["error"] as? [String: Any] { finish(.failed(error["message"] as? String ?? "Codexの実行に失敗しました。")) }
            else if remote["status"] as? String == "completed" { finish(.completed) }
            else if remote["status"] as? String == "interrupted" { finish(.interrupted) }
            else { finish(.failed("Codexの実行が正常に完了しませんでした。")) }
        case "error":
            if params["willRetry"] as? Bool != true {
                let error = params["error"] as? [String: Any]
                finish(.failed(error?["message"] as? String ?? "Codexの実行に失敗しました。"))
            }
        default: break
        }
    }

    private func resolve(_ id: String, outcome: AgentRequestOutcome) {
        guard var pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.request.outcome = outcome
        emitter.yield(.output(.request(pending.request)))
    }

    private func finish(_ event: AgentEvent) {
        for id in Array(pendingRequests.keys) { resolve(id, outcome: .unanswered) }
        turn = nil
        stopRequested = false
        emitter.yield(event)
    }
}
