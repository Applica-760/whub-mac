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
        models = loaded
        return loaded.flatMap(\.options)
    }

    func loadSkills() async throws -> [AgentSkill] { throw unsupported("Skill一覧") }

    func loadStatus() async throws -> [AgentContent] { throw unsupported("状態の表示") }

    func changeModel(_ option: AgentModelOption) async throws { throw unsupported("モデルの変更") }

    func respond(to requestID: String, with response: AgentResponse) async throws { throw unsupported("要求への回答") }

    func loadHistory(cursor: String?) async throws -> AgentHistoryPage { throw unsupported("履歴の一覧") }

    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot { throw unsupported("会話の再開") }

    func close() {
        guard !isClosed else { return }
        isClosed = true
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
        return try ClaudeCodeMapping.input(input)
    }

    private func prepareSession() throws {
        if needsResume { throw unsupported("接続が終了した会話の再開") }
    }

    private func unsupported(_ operation: String) -> AgentError {
        AgentError(.unsupported, "Claude Codeの\(operation)は未実装です。")
    }

    func receive(_ message: [String: Any]) {
        guard !isClosed else { return }
        if message["type"] as? String == "control_request", let requestID = message["request_id"] as? String {
            do {
                if (message["request"] as? [String: Any])?["subtype"] as? String == "can_use_tool" {
                    try client.respond(requestID: requestID,
                                       response: ["behavior": "deny", "message": "whubはこの承認要求に未対応です。"])
                } else {
                    try client.rejectUnsupported(requestID: requestID)
                }
            } catch { finish(.failed(error.localizedDescription)) }
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

    private func finish(_ event: AgentEvent) {
        turn = nil
        stopRequested = false
        emitter.yield(event)
    }
}
