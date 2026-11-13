import Foundation

@MainActor
final class ClaudeCodeAdapter: AgentAdapter {
    let kind = AgentKind.claudeCode
    let events: AsyncStream<AgentEvent>
    private let emitter: AsyncStream<AgentEvent>.Continuation
    private let client: ClaudeCodeClient
    private var directory: String?
    private var isClosed = false
    private var sessionID: String?
    private var turn: ClaudeCodeTurn?
    private var stopRequested = false
    private var needsResume = false
    private var models: [ClaudeCodeModel] = []
    private var skills: [AgentSkill] = []
    private var settings: [String: Any] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]

    private struct PendingRequest {
        let controlID: String
        let input: [String: Any]
        var request: AgentRequest
    }

    init(client: ClaudeCodeClient? = nil) {
        let client = client ?? ClaudeCodeClient()
        self.client = client
        let stream = AsyncStream<AgentEvent>.makeStream()
        events = stream.stream
        emitter = stream.continuation
        client.onEvent = { [weak self] in self?.receive($0) }
        client.onDisconnect = { [weak self] message in
            guard let self, !self.isClosed else { return }
            self.needsResume = self.sessionID != nil
            self.finish(.failed(message))
        }
    }

    func connect(directory: String) async throws {
        guard !isClosed else { throw CancellationError() }
        try validateDirectory(directory)
        guard self.directory == nil || self.directory == directory else {
            throw AgentError(.adapterFailed, "接続済みSessionの作業ディレクトリは変更できません。")
        }
        self.directory = directory
        try await client.connect(directory: directory)
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
    }

    func send(_ input: [AgentInput]) async throws {
        guard turn == nil else { throw AgentError(.adapterFailed, "会話は実行中です。追加送信を使用してください。") }
        let payload = try inputPayload(input)
        let active = ClaudeCodeTurn()
        turn = active
        stopRequested = false
        do {
            try prepareSession()
            try await connectClient()
            guard turn?.id == active.id else { throw CancellationError() }
            if stopRequested { finish(.interrupted); return }
            try client.send(payload)
        } catch {
            if turn?.id == active.id {
                for id in Array(pendingRequests.keys) { resolve(id, outcome: .unanswered) }
                turn = nil
                stopRequested = false
            }
            throw error
        }
    }

    func sendAdditionalInput(_ input: [AgentInput]) async throws { throw unsupported("追加送信") }

    func interrupt() async throws {
        guard turn != nil else { return }
        stopRequested = true
        guard client.isConnected else { return }
        do { _ = try await client.request("interrupt") }
        catch {
            stopRequested = false
            throw error
        }
    }

    func loadModelOptions() async throws -> [AgentModelOption] {
        try await connectClient()
        var seen = Set<String>()
        let loaded = try (client.initialization["models"] as? [[String: Any]] ?? []).map(ClaudeCodeModel.init)
            .filter { seen.insert($0.id).inserted }
        let result = try await client.request("get_settings")
        guard let values = result["effective"] as? [String: Any] else {
            throw AgentError(.adapterFailed, "起動時のモデル設定を取得できませんでした。")
        }
        models = loaded
        if settings.isEmpty {
            settings["model"] = values["model"] as? String ?? "default"
            settings["effort"] = values["effortLevel"] as? String
        }
        publishModelOption()
        return loaded.flatMap(\.options)
    }

    func loadSkills() async throws -> [AgentSkill] {
        try await connectClient()
        let result = try await client.request("reload_skills")
        guard let values = result["skills"] as? [[String: Any]] else {
            throw AgentError(.adapterFailed, "Skill一覧の形式が不正です。")
        }
        var seen = Set<String>()
        let loaded = try values.map { value in
            guard let name = value["name"] as? String, !name.isEmpty else {
                throw AgentError(.adapterFailed, "Skillの識別子を確認できませんでした。")
            }
            return AgentSkill(id: name, name: name, description: value["description"] as? String ?? "")
        }.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        skills = loaded
        return loaded
    }

    func loadStatus() async throws -> [AgentContent] {
        try await connectClient()
        let activeSettings = settings
        let permissionMode = client.initialization["current_permission_mode"] as? String
        var status: [String: Any]?
        var context: [String: Any]?
        var usage: [String: Any]?
        var failures: [ClaudeCodeStatusFailure] = []
        do { status = try await client.request("get_status") } catch { failures.append(.status) }
        do { context = try await client.request("get_context_usage") } catch { failures.append(.context) }
        do { usage = try await client.request("get_usage") } catch { failures.append(.usage) }
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        return [.code(ClaudeCodeMapping.statusText(ClaudeCodeStatusSnapshot(status: status, settings: activeSettings,
            permissionMode: permissionMode, context: context, usage: usage, failures: failures)))]
    }

    func changeModel(_ option: AgentModelOption) async throws {
        guard turn == nil, let selected = models.flatMap(\.options).first(where: { $0.id == option.id }) else {
            throw AgentError(.invalidInput, "現在選択できるモデルとEffortを指定してください。")
        }
        try await connectClient()
        _ = try await client.request("set_model", ["model": selected.modelID])
        _ = try await client.request("apply_flag_settings", ["settings": ["effortLevel": selected.effort as Any? ?? NSNull()]])
        settings["model"] = selected.modelID
        settings["effort"] = selected.effort
        publishModelOption()
    }

    func respond(to requestID: String, with response: AgentResponse) async throws {
        guard !isClosed, let pending = pendingRequests[requestID] else {
            throw AgentError(.notFound, "未回答の要求を確認できませんでした。")
        }
        let mapped = try ClaudeCodeMapping.response(response, to: pending.request, input: pending.input)
        try client.respond(requestID: pending.controlID, response: mapped.result)
        resolve(requestID, outcome: mapped.outcome)
    }

    func loadHistory(cursor: String?) async throws -> AgentHistoryPage { throw unsupported("履歴の一覧") }

    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot { throw unsupported("会話の再開") }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pendingRequests.removeAll()
        turn = nil
        client.disconnect()
        emitter.finish()
    }

    private func connectClient() async throws {
        guard !isClosed, !Task.isCancelled, let directory else { throw CancellationError() }
        try await client.connect(directory: directory)
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
    }

    private func validateDirectory(_ directory: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentError(.adapterFailed, "作業フォルダが存在しません: \(directory)")
        }
    }

    private func inputPayload(_ input: [AgentInput]) throws -> [[String: Any]] {
        guard !input.isEmpty, let directory else { throw AgentError(.adapterFailed, "入力または接続先を確認できませんでした。") }
        try validateDirectory(directory)
        return try ClaudeCodeMapping.input(input, skills: skills)
    }

    private func prepareSession() throws {
        if needsResume { throw unsupported("接続が終了した会話の再開") }
    }

    private var selectedOption: AgentModelOption? {
        guard let model = settings["model"] as? String else { return nil }
        let effort = settings["effort"] as? String
        if let option = models.flatMap(\.options).first(where: { $0.modelID == model && $0.effort == effort }) {
            return option
        }
        return AgentModelOption(id: AgentJSON.pretty([model, effort as Any? ?? NSNull()]), modelID: model,
            displayName: model, description: "", effort: effort, isDefaultEffort: false)
    }

    private func publishModelOption() {
        if let option = selectedOption { emitter.yield(.modelOptionChanged(option)) }
    }

    private func unsupported(_ operation: String) -> AgentError {
        AgentError(.unsupported, "Claude Codeの\(operation)は未実装です。")
    }

    func receive(_ message: [String: Any]) {
        guard !isClosed else { return }
        if message["type"] as? String == "control_request", let controlID = message["request_id"] as? String {
            let params = message["request"] as? [String: Any] ?? [:]
            do {
                guard params["subtype"] as? String == "can_use_tool" else {
                    try client.rejectUnsupported(requestID: controlID)
                    return
                }
                do {
                    guard turn != nil else { throw AgentError(.adapterFailed, "要求の対象となる実行を確認できませんでした。") }
                    let request = try ClaudeCodeMapping.request(params, controlID: controlID)
                    guard pendingRequests[request.id] == nil else { return }
                    pendingRequests[request.id] = PendingRequest(controlID: controlID,
                        input: params["input"] as? [String: Any] ?? [:], request: request)
                    emitter.yield(.output(.request(request)))
                } catch {
                    try client.respond(requestID: controlID,
                                       response: ["behavior": "deny", "message": error.localizedDescription])
                }
            } catch { finish(.failed(error.localizedDescription)) }
            return
        }
        if message["type"] as? String == "control_cancel_request", let controlID = message["request_id"] as? String {
            resolve(ClaudeCodeMapping.requestID(controlID), outcome: .resolved)
            return
        }
        if let id = message["session_id"] as? String, !id.isEmpty, id != sessionID {
            sessionID = id
            emitter.yield(.conversationIDChanged(id))
        }
        guard message["parent_tool_use_id"] as? String == nil, var active = turn else { return }
        switch message["type"] as? String {
        case "stream_event":
            guard let event = message["event"] as? [String: Any], let id = active.stream(event) else { return }
            turn = active
            if let item = active.items.first(where: { $0.id == id }) { emitter.yield(.output(ClaudeCodeMapping.output(item))) }
        case "assistant":
            guard let content = message["message"] as? [String: Any] else { return }
            let ids = active.complete(content)
            turn = active
            for item in active.items where ids.contains(item.id) { emitter.yield(.output(ClaudeCodeMapping.output(item))) }
        case "user":
            let blocks = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let ids = blocks.filter { $0["type"] as? String == "tool_result" }.compactMap { active.completeTool($0) }
            turn = active
            for item in active.items where ids.contains(item.id) { emitter.yield(.output(ClaudeCodeMapping.output(item))) }
        case "result":
            active.inferFinalAnswerIfNeeded()
            for item in active.items { emitter.yield(.output(ClaudeCodeMapping.output(item))) }
            if message["is_error"] as? Bool == false { finish(.completed) }
            else if stopRequested { finish(.interrupted) }
            else {
                let errors = (message["errors"] as? [String])?.joined(separator: "\n")
                finish(.failed(message["result"] as? String ?? errors ?? "Claude Codeの実行に失敗しました。"))
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
