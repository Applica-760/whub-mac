import AppKit
import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class CodexStore: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft = ""
    @Published var draftImages: [CodexImageAttachment] = []
    @Published var selectedSkills: [CodexSkill] = []
    @Published private(set) var turns: [CodexTurn] = []
    @Published private(set) var requests: [CodexRequest] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isStopping = false
    @Published private(set) var isChangingModel = false
    private(set) var settings: [String: Any] = [:]
    private(set) var tokenUsage: [String: Any]?
    @Published private(set) var model = "Codexの既存設定"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isResuming = false
    @Published private(set) var resumedDirectory: String?
    private var historyGeneration = UUID()
    private(set) var threadID: String?
    var onCompletionChange: ((Bool) -> Void)?
    var onNotification: ((String) -> Void)?
    @Published private(set) var notificationDate: Date?
    private let client: CodexClient
    let commands: CodexCommandsStore
    private let context: ModelContext
    private var stopRequested = false
    private var needsResume = false
    private var pendingInput: (text: String, images: [CodexImageAttachment])?

    init(context: ModelContext,
         request: ((String, [String: Any], String) async throws -> [String: Any])? = nil) {
        self.context = context
        let client = CodexClient()
        self.client = client
        commands = CodexCommandsStore(request: request ?? { method, params, directory in
            try await client.connect(directory: directory)
            return try await client.request(method, params)
        })
        client.onEvent = { [weak self] in self?.receive($0, params: $1, requestID: $2) }
        client.onDisconnect = { [weak self] message in
            self?.fail(message)
            self?.needsResume = true
        }
    }

    var directory: String {
        resumedDirectory ?? (try? HostStore(context: context).fetchHosts().first { $0 is LocalHost }?.basePath)
            ?? NSHomeDirectory()
    }

    var canSend: Bool {
        !isBusy && !isResuming && !isChangingModel && !directory.isEmpty
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty)
    }

    func addImages(_ images: [NSImage]) {
        for image in images {
            guard let attachment = CodexImageAttachment(image: image) else {
                errorMessage = "画像を読み込めませんでした。画像をコピーし直してください。"
                continue
            }
            draftImages.append(attachment)
        }
    }

    private var activeTurnIndex: Int? {
        turns.lastIndex { $0.status == "inProgress" }
    }

    func resume(_ thread: CodexRecentThread) async -> Bool {
        guard !isBusy, !isResuming, !isChangingModel, !commands.isLoadingThreads, threadID == nil, turns.isEmpty else { return false }
        let generation = historyGeneration
        isResuming = true
        errorMessage = nil
        defer { if generation == historyGeneration { isResuming = false } }
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: thread.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CodexError(message: "会話の作業フォルダが存在しません: \(thread.directory)")
            }
            let metadata = try await commands.request("thread/read", ["threadId": thread.id], thread.directory)
            guard let stored = metadata["thread"] as? [String: Any], stored["id"] as? String == thread.id else {
                throw CodexError(message: "指定した会話を読み込めませんでした。")
            }
            var params: [String: Any] = ["threadId": thread.id]
            let paginated = stored["historyMode"] as? String == "paginated"
            if paginated { params["excludeTurns"] = true }
            var result = try await commands.request("thread/resume", params, thread.directory)
            if paginated {
                var turns: [[String: Any]] = []
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    guard generation == historyGeneration else { return false }
                    var pageParams: [String: Any] = ["threadId": thread.id, "limit": 100,
                                                    "sortDirection": "asc", "itemsView": "full"]
                    if let cursor { pageParams["cursor"] = cursor }
                    let page = try await commands.request("thread/turns/list", pageParams, thread.directory)
                    guard let data = page["data"] as? [[String: Any]] else {
                        throw CodexError(message: "会話履歴を読み込めませんでした。")
                    }
                    turns += data
                    cursor = page["nextCursor"] as? String
                    if let cursor, !seen.insert(cursor).inserted {
                        throw CodexError(message: "会話履歴の取得位置が進みませんでした。")
                    }
                } while cursor != nil
                var hydrated = result["thread"] as? [String: Any] ?? [:]
                hydrated["turns"] = turns
                result["thread"] = hydrated
            }
            guard generation == historyGeneration else { return false }
            try restoreHistory(result, expectedID: thread.id)
            return true
        } catch {
            if generation == historyGeneration {
                client.disconnect()
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func restoreHistory(_ result: [String: Any], expectedID: String) throws {
        guard threadID == nil, turns.isEmpty else {
            throw CodexError(message: "既存の会話を上書きできません。")
        }
        let history = try CodexThreadHistory(result, expectedID: expectedID)
        threadID = expectedID
        resumedDirectory = history.directory
        updateSettings(result)
        turns = history.turns
        needsResume = false
    }

    func appendCommandOutput(_ command: CodexCommand, _ output: CodexCommandOutput) {
        let item = CodexItem(id: UUID().uuidString, type: "commandOutput", phase: nil,
                             text: nil, status: "completed", data: ["command": command.rawValue], output: output)
        turns.append(CodexTurn(prompt: command.rawValue, items: [item], status: "completed"))
    }

    func updateSettings(_ result: [String: Any]) {
        let keys = ["model", "modelProvider", "effort", "reasoningEffort", "sandboxPolicy", "sandbox",
                    "approvalPolicy", "approvalsReviewer", "serviceTier", "instructionSources"]
        settings.merge(result.filter { keys.contains($0.key) }) { _, new in new }
        model = result["model"] as? String ?? model
        // Start/resume and settings notifications use different field names.
        if let effort = result["reasoningEffort"] { settings["effort"] = effort }
        if let sandbox = result["sandbox"] { settings["sandboxPolicy"] = sandbox }
    }

    private func prepareThread() async throws {
        let generation = historyGeneration
        if threadID == nil {
            let result = try await commands.request("thread/start", ["cwd": directory], directory)
            guard generation == historyGeneration else { throw CancellationError() }
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                throw CodexError(message: "Codexから会話IDを取得できませんでした。")
            }
            threadID = id
            updateSettings(result)
        } else if needsResume, let threadID {
            var params: [String: Any] = ["threadId": threadID, "model": model]
            if let effort = settings["effort"] as? String {
                params["config"] = ["model_reasoning_effort": effort]
            }
            let result = try await commands.request("thread/resume", params, directory)
            guard generation == historyGeneration else { throw CancellationError() }
            updateSettings(result)
            needsResume = false
        }
    }

    func changeModel(_ choice: CodexModel, effort: String) async throws {
        guard !isBusy, !isResuming, !isChangingModel else {
            throw CodexError(message: "作業または会話の再開が終わってからモデルを変更してください。")
        }
        guard choice.efforts.contains(where: { $0.reasoningEffort == effort }) else {
            throw CodexError(message: "このモデルで利用できない推論設定です。")
        }
        isChangingModel = true
        defer { isChangingModel = false }
        let generation = historyGeneration
        try await prepareThread()
        guard generation == historyGeneration, let threadID else { throw CancellationError() }
        _ = try await commands.request("thread/settings/update", choice.parameters(threadID: threadID, effort: effort), directory)
        guard generation == historyGeneration else { throw CancellationError() }
        settings["model"] = choice.model
        settings["effort"] = effort
        model = choice.model
        appendCommandOutput(.model, .modelChanged(name: choice.displayName, effort: effort))
    }

    func send(skills selectedSkills: [CodexSkill] = []) async {
        guard canSend else { return }
        let cwd = directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "ローカルHostのBasePathが存在しません。Host設定を確認してください。"
            return
        }
        if !draftImages.isEmpty, commands.models.first(where: { $0.model == model })?.supportsImages == false {
            errorMessage = "このモデルは画像入力に対応していません。モデルを変更するか、添付画像を取り除いてください。"
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftImages
        pendingInput = (prompt, images)
        onCompletionChange?(false)
        draft = ""
        draftImages = []
        errorMessage = nil
        stopRequested = false
        isBusy = true
        turns.append(CodexTurn(prompt: prompt, images: images))
        do {
            try await prepareThread()
            guard !stopRequested else { finish("interrupted"); return }
            guard let threadID else { return }
            var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
            input += images.map(\.input)
            input += selectedSkills.map { ["type": "skill", "name": $0.name, "path": $0.path] }
            let result = try await commands.request("turn/start", ["threadId": threadID, "input": input], directory)
            if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, isBusy, let index = activeTurnIndex {
                turns[index].remoteID = id
                if stopRequested { await interrupt() }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    func interrupt() async {
        guard isBusy else { return }
        stopRequested = true
        isStopping = true
        guard let threadID, let index = activeTurnIndex, let turnID = turns[index].remoteID else { return }
        for attempt in 0..<10 {
            guard isBusy else { return }
            do {
                _ = try await commands.request("turn/interrupt", ["threadId": threadID, "turnId": turnID], directory)
                return
            } catch {
                guard isBusy else { return }
                // turn/start can reply before the server has activated the turn.
                if error.localizedDescription == "no active turn to interrupt", attempt < 9 {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                errorMessage = error.localizedDescription
                isStopping = false
                return
            }
        }
    }

    func reset() {
        guard !isBusy, !isResuming, !isChangingModel else { return }
        historyGeneration = UUID()
        commands.invalidate()
        onCompletionChange?(false)
        client.disconnect()
        threadID = nil
        resumedDirectory = nil
        needsResume = false
        turns = []
        draftImages = []
        pendingInput = nil
        requests = []
        errorMessage = nil
        model = "Codexの既存設定"
        settings = [:]
        tokenUsage = nil
        appendCommandOutput(.new, .newConversation)
    }

    func disconnect() {
        historyGeneration = UUID()
        commands.invalidate()
        isResuming = false
        needsResume = threadID != nil
        client.disconnect()
    }

    func approve(_ request: CodexRequest, allow: Bool) {
        let result: [String: Any] = request.method == "item/permissions/requestApproval"
            ? ["permissions": allow ? (request.params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"]
            : ["decision": allow ? "accept" : "decline"]
        answer(request, result: result, outcome: allow ? .accepted : .declined)
    }

    func resolveRequest(_ id: String, outcome: CodexRequestOutcome) {
        requests.removeAll { $0.id == id }
        for turn in turns.indices {
            if let index = turns[turn].approvals.firstIndex(where: { $0.id == id && $0.outcome == nil }) {
                turns[turn].approvals[index].outcome = outcome
            }
        }
    }

    func answer(_ request: CodexRequest, result: [String: Any], outcome: CodexRequestOutcome? = nil) {
        guard requests.contains(where: { $0.id == request.id }) else { return }
        do {
            try client.respond(id: request.rpcID, result: result)
            resolveRequest(request.id, outcome: outcome ?? .answered)
        } catch { fail(error.localizedDescription) }
    }

    func receive(_ method: String, params: [String: Any], requestID: Any?) {
        if let requestID {
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput"].contains(method) {
                var details = params
                if method == "item/fileChange/requestApproval",
                   let index = activeTurnIndex,
                   let item = turns[index].items.first(where: { $0.id == params["itemId"] as? String }) {
                    details["changes"] = item.data["changes"] as? [[String: Any]] ?? []
                }
                let request = CodexRequest(rpcID: requestID, method: method, params: details)
                guard !requests.contains(where: { $0.id == request.id }) else { return }
                requests.append(request)
                if request.isApproval, let index = activeTurnIndex {
                    turns[index].approvals.append(request)
                }
                if request.isApproval {
                    notificationDate = Date()
                    onNotification?("Blow")
                }
            } else {
                do { try client.rejectUnsupported(id: requestID) } catch { fail(error.localizedDescription) }
                errorMessage = "このMVPでは未対応の要求です: \(method)。要求は許可していません。"
            }
            return
        }
        if method == "serverRequest/resolved", let id = params["requestId"] {
            resolveRequest(CodexJSON.pretty(id), outcome: .resolved)
            return
        }
        guard params["threadId"] as? String == threadID else { return }
        if method == "thread/settings/updated", let settings = params["threadSettings"] as? [String: Any] {
            updateSettings(settings)
            return
        }
        if method == "thread/tokenUsage/updated" {
            tokenUsage = params["tokenUsage"] as? [String: Any]
            return
        }
        guard let index = activeTurnIndex else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any] {
            turns[index].remoteID = turn["id"] as? String
            return
        }
        if let turnID = params["turnId"] as? String,
           let activeID = turns[index].remoteID, turnID != activeID { return }
        switch method {
        case "item/started", "item/completed":
            if let item = params["item"] as? [String: Any] { turns[index].updateItem(item, completed: method == "item/completed") }
        case "item/agentMessage/delta", "item/commandExecution/outputDelta", "item/plan/delta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String,
                  let itemIndex = turns[index].items.firstIndex(where: { $0.id == id }) else { return }
            turns[index].items[itemIndex].delta += delta
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == turns[index].remoteID else { return }
            if let error = turn["error"] as? [String: Any] { errorMessage = error["message"] as? String }
            turns[index].inferFinalAnswerIfNeeded()
            finish(turn["status"] as? String ?? "completed")
            if turn["status"] as? String == "completed", turn["error"] as? [String: Any] == nil {
                onCompletionChange?(true)
                notificationDate = Date()
                onNotification?("Glass")
            }
        case "error":
            let error = params["error"] as? [String: Any]
            errorMessage = error?["message"] as? String ?? "Codexの実行中にエラーが発生しました。"
            if params["willRetry"] as? Bool != true { finish("failed") }
        default: break
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        if isBusy { finish("failed") }
    }

    private func finish(_ status: String) {
        for request in requests { resolveRequest(request.id, outcome: .unanswered) }
        if let index = activeTurnIndex { turns[index].status = status }
        if status != "completed", let pendingInput {
            if draft.isEmpty { draft = pendingInput.text }
            draftImages.insert(contentsOf: pendingInput.images, at: 0)
        }
        pendingInput = nil
        isBusy = false
        isStopping = false
        requests = []
    }
}
