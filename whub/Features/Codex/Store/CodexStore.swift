import AppKit
import Combine
import Foundation
import SwiftData
import WhubCore

enum CodexCommand: String, CaseIterable {
    case new = "/new"
    case stop = "/stop"
    case skills = "/skills"
    case status = "/status"
    case resume = "/resume"

    var description: String {
        switch self {
        case .new: "新しい会話"
        case .stop: "作業を停止"
        case .skills: "Skillを選択"
        case .status: "状態を確認"
        case .resume: "過去の会話を再開"
        }
    }
}

struct CodexItem: Identifiable {
    let id: String
    var type: String
    var phase: String?
    var title: String
    var text: String
    var status: String
    var isAnswer: Bool { type == "commandOutput" || (type == "agentMessage" && phase == "final_answer") }
}

struct CodexTurn: Identifiable {
    let id = UUID()
    var remoteID: String?
    let prompt: String
    var images: [CodexImageAttachment] = []
    var approvals: [CodexRequest] = []
    var items: [CodexItem] = []
    var status = "inProgress"
    var history: [CodexItem] { items.filter { !$0.isAnswer } }
    var answers: [CodexItem] { items.filter(\.isAnswer) }

    mutating func updateItem(_ data: [String: Any], completed: Bool) {
        guard let id = data["id"] as? String, let type = data["type"] as? String,
              type != "userMessage", type != "reasoning" else { return }
        let existing = items.firstIndex { $0.id == id }
        var title = type
        var text = data["text"] as? String
        switch type {
        case "agentMessage": title = "進捗メッセージ"
        case "commandExecution":
            title = data["command"] as? String ?? "コマンド実行"
            text = data["aggregatedOutput"] as? String
        case "fileChange":
            title = "ファイル変更"
            text = (data["changes"] as? [[String: Any]] ?? []).map {
                ($0["path"] as? String ?? "") + "\n" + ($0["diff"] as? String ?? "")
            }.joined(separator: "\n\n")
        case "webSearch": title = "Web検索 · " + (data["query"] as? String ?? "")
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            title = data["tool"] as? String ?? type
        case "plan": title = "計画"
        case "contextCompaction": title = "会話を圧縮"
        default: break
        }
        if text == nil, type != "agentMessage", type != "commandExecution" {
            text = CodexStore.pretty(data)
        }
        let item = CodexItem(id: id, type: type, phase: data["phase"] as? String,
                             title: title, text: text ?? existing.map { items[$0].text } ?? "",
                             status: data["status"] as? String ?? (completed ? "completed" : "inProgress"))
        if let existing { items[existing] = item } else { items.append(item) }
    }

}

struct CodexRequest: Identifiable {
    let rpcID: Any
    let method: String
    let params: [String: Any]
    var outcome: String? = nil
    var isApproval: Bool { method != "item/tool/requestUserInput" }
    var id: String { CodexStore.pretty(rpcID) }
}

struct CodexSkill: Identifiable {
    let name: String
    let description: String
    let path: String
    var id: String { path }
    func isMentioned(in text: String) -> Bool {
        let pattern = "(?<!\\S)\\$" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

struct CodexImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let pngData: Data

    init?(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        self.image = image
        pngData = png
    }

    var input: [String: String] {
        ["type": "image", "url": "data:image/png;base64," + pngData.base64EncodedString()]
    }
}

@MainActor
final class CodexStore: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft = ""
    @Published var draftImages: [CodexImageAttachment] = []
    @Published var selectedSkills: [CodexSkill] = []
    @Published private(set) var skills: [CodexSkill] = []
    @Published private(set) var skillError: String?
    @Published private(set) var isLoadingSkills = false
    private var skillsDirectory = ""
    @Published private(set) var turns: [CodexTurn] = []
    @Published private(set) var requests: [CodexRequest] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isStopping = false
    @Published private(set) var model = "Codexの既存設定"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isResuming = false
    @Published private(set) var recentThreads: [CodexRecentThread] = []
    @Published private(set) var isLoadingThreads = false
    @Published private(set) var threadListError: String?
    @Published private(set) var nextThreadCursor: String?
    @Published private(set) var resumedDirectory: String?
    private var historyGeneration = UUID()
    private(set) var threadID: String?
    var onCompletionChange: ((Bool) -> Void)?
    var onNotification: ((String) -> Void)?
    @Published private(set) var notificationDate: Date?
    private let client = CodexClient()
    private let context: ModelContext
    private var stopRequested = false
    private var needsResume = false
    private var pendingInput: (text: String, images: [CodexImageAttachment])?

    init(context: ModelContext) {
        self.context = context
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
        !isBusy && !isResuming && !directory.isEmpty
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

    func loadRecentThreads(more: Bool = false) async {
        guard !isLoadingThreads, !isResuming, !more || nextThreadCursor != nil else { return }
        let generation = historyGeneration
        isLoadingThreads = true
        threadListError = nil
        defer { if generation == historyGeneration { isLoadingThreads = false } }
        do {
            try await client.connect(directory: directory)
            var params: [String: Any] = ["limit": 20, "sortKey": "updated_at", "sortDirection": "desc",
                                        "sourceKinds": ["cli", "appServer", "vscode"], "archived": false]
            if more { params["cursor"] = nextThreadCursor }
            let result = try await client.request("thread/list", params)
            guard generation == historyGeneration else { return }
            guard let data = result["data"] as? [[String: Any]] else {
                throw CodexError(message: "会話一覧を読み込めませんでした。")
            }
            let threads = try data.map(CodexRecentThread.init)
            var seen = Set(more ? recentThreads.map(\.id) : [])
            let additions = threads.filter { seen.insert($0.id).inserted }
            recentThreads = (more ? recentThreads : []) + additions
            nextThreadCursor = result["nextCursor"] as? String
        } catch {
            if generation == historyGeneration { threadListError = error.localizedDescription }
        }
    }

    func resume(_ thread: CodexRecentThread) async -> Bool {
        guard !isBusy, !isResuming, !isLoadingThreads, threadID == nil, turns.isEmpty else { return false }
        let generation = historyGeneration
        isResuming = true
        errorMessage = nil
        defer { if generation == historyGeneration { isResuming = false } }
        do {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: thread.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CodexError(message: "会話の作業フォルダが存在しません: \(thread.directory)")
            }
            try await client.connect(directory: thread.directory)
            let metadata = try await client.request("thread/read", ["threadId": thread.id])
            guard let stored = metadata["thread"] as? [String: Any], stored["id"] as? String == thread.id else {
                throw CodexError(message: "指定した会話を読み込めませんでした。")
            }
            var params: [String: Any] = ["threadId": thread.id]
            let paginated = stored["historyMode"] as? String == "paginated"
            if paginated { params["excludeTurns"] = true }
            var result = try await client.request("thread/resume", params)
            if paginated {
                var turns: [[String: Any]] = []
                var cursor: String?
                var seen = Set<String>()
                repeat {
                    guard generation == historyGeneration else { return false }
                    var pageParams: [String: Any] = ["threadId": thread.id, "limit": 100,
                                                    "sortDirection": "asc", "itemsView": "full"]
                    if let cursor { pageParams["cursor"] = cursor }
                    let page = try await client.request("thread/turns/list", pageParams)
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
        model = history.model
        turns = history.turns
        needsResume = false
    }

    func runCommand(_ command: CodexCommand) async {
        let output: String
        switch command {
        case .resume:
            await loadRecentThreads()
            return
        case .new:
            reset()
            return
        case .stop:
            let wasBusy = isBusy
            await interrupt()
            output = wasBusy ? (isStopping ? "停止を要求しました。" : errorMessage ?? "作業を停止しました。") : "実行中の作業はありません。"
        case .skills:
            output = await loadSkills(forceReload: true)
        case .status:
            output = await statusText()
        }
        appendCommandOutput(command, output)
    }

    private func appendCommandOutput(_ command: CodexCommand, _ output: String) {
        let item = CodexItem(id: UUID().uuidString, type: "commandOutput", phase: nil,
                             title: command.rawValue, text: "```\n" + output + "\n```", status: "completed")
        turns.append(CodexTurn(prompt: command.rawValue, items: [item], status: "completed"))
    }

    private func statusText() async -> String {
        var output = "作業フォルダ: \(directory)\n会話: \(threadID ?? "未開始")"
        do { try await client.connect(directory: directory) }
        catch { return output + "\n接続: " + error.localizedDescription }
        let requests: [(String, [String: Any])] = [
            ("config/read", ["includeLayers": false]), ("account/read", ["refreshToken": false]),
            ("account/rateLimits/read", [:])
        ]
        for (method, params) in requests {
            do {
                var result = try await client.request(method, params)
                if method == "config/read", let config = result["config"] as? [String: Any] {
                    // Provider configuration can contain credentials; show only status fields.
                    result = config.filter { ["model", "model_reasoning_effort", "model_provider", "service_tier", "sandbox_mode", "approval_policy", "approvals_reviewer"].contains($0.key) }
                    if threadID != nil { result["model"] = model }
                }
                output += "\n\n" + method + "\n" + Self.pretty(result)
                if method == "account/read" {
                    guard let account = result["account"] as? [String: Any], account["type"] as? String != "apiKey" else { break }
                }
            } catch {
                output += "\n\n" + method + "\n" + error.localizedDescription
                if method == "account/read" { break }
            }
        }
        return output
    }

    @discardableResult
    func loadSkills(forceReload: Bool = false) async -> String {
        let cwd = directory
        guard !cwd.isEmpty else { return "作業フォルダがありません。" }
        isLoadingSkills = true
        if skillsDirectory != cwd { skills = [] }
        skillError = nil
        defer { if directory == cwd { isLoadingSkills = false } }
        do {
            try await client.connect(directory: cwd)
            let result = try await client.request("skills/list", ["cwds": [cwd], "forceReload": forceReload])
            guard directory == cwd else { return "作業フォルダが変更されました。再実行してください。" }
            let entries = result["data"] as? [[String: Any]] ?? []
            skills = entries.flatMap { $0["skills"] as? [[String: Any]] ?? [] }.compactMap {
                guard $0["enabled"] as? Bool != false,
                      let name = $0["name"] as? String, let path = $0["path"] as? String else { return nil }
                return CodexSkill(name: name, description: $0["description"] as? String ?? "", path: path)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            skillsDirectory = cwd
            let errors = entries.flatMap { $0["errors"] as? [[String: Any]] ?? [] }
            if !errors.isEmpty { skillError = Self.pretty(errors) }
            return Self.pretty(result)
        } catch {
            if directory == cwd { skillError = error.localizedDescription }
            return error.localizedDescription
        }
    }

    func send(skills selectedSkills: [CodexSkill] = []) async {
        guard canSend else { return }
        let cwd = directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "ローカルHostのBasePathが存在しません。Host設定を確認してください。"
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
            try await client.connect(directory: cwd)
            if threadID == nil {
                let result = try await client.request("thread/start", ["cwd": cwd])
                guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                    throw CodexError(message: "Codexから会話IDを取得できませんでした。")
                }
                threadID = id
                model = result["model"] as? String ?? model
            } else if needsResume, let threadID {
                _ = try await client.request("thread/resume", ["threadId": threadID])
                needsResume = false
            }
            guard !stopRequested else { finish("interrupted"); return }
            guard let threadID else { return }
            var input: [[String: Any]] = prompt.isEmpty ? [] : [["type": "text", "text": prompt]]
            input += images.map(\.input)
            input += selectedSkills.map { ["type": "skill", "name": $0.name, "path": $0.path] }
            let result = try await client.request("turn/start", ["threadId": threadID, "input": input])
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
                _ = try await client.request("turn/interrupt", ["threadId": threadID, "turnId": turnID])
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
        guard !isBusy, !isResuming else { return }
        historyGeneration = UUID()
        isLoadingThreads = false
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
        appendCommandOutput(.new, "新しい会話を開始しました。")
    }

    func disconnect() {
        historyGeneration = UUID()
        isLoadingThreads = false
        isResuming = false
        client.disconnect()
    }

    func approve(_ request: CodexRequest, allow: Bool) {
        let result: [String: Any] = request.method == "item/permissions/requestApproval"
            ? ["permissions": allow ? (request.params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"]
            : ["decision": allow ? "accept" : "decline"]
        answer(request, result: result, outcome: allow ? "承認済み" : "拒否済み")
    }

    func resolveRequest(_ id: String, outcome: String) {
        requests.removeAll { $0.id == id }
        for turn in turns.indices {
            if let index = turns[turn].approvals.firstIndex(where: { $0.id == id && $0.outcome == nil }) {
                turns[turn].approvals[index].outcome = outcome
            }
        }
    }

    func answer(_ request: CodexRequest, result: [String: Any], outcome: String? = nil) {
        guard requests.contains(where: { $0.id == request.id }) else { return }
        do {
            try client.respond(id: request.rpcID, result: result)
            resolveRequest(request.id, outcome: outcome ?? "回答済み")
        } catch { fail(error.localizedDescription) }
    }

    func receive(_ method: String, params: [String: Any], requestID: Any?) {
        if let requestID {
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput"].contains(method) {
                var details = params
                if method == "item/fileChange/requestApproval",
                   let index = activeTurnIndex,
                   let item = turns[index].items.first(where: { $0.id == params["itemId"] as? String }) {
                    details["changePreview"] = item.text
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
            resolveRequest(Self.pretty(id), outcome: "解決済み")
            return
        }
        guard params["threadId"] as? String == threadID, let index = activeTurnIndex else { return }
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
            turns[index].items[itemIndex].text += delta
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any],
                  turn["id"] as? String == turns[index].remoteID else { return }
            if let error = turn["error"] as? [String: Any] { errorMessage = error["message"] as? String }
            // Older models omit phase; only the last non-commentary message is the answer.
            if turns[index].answers.isEmpty,
               let last = turns[index].items.lastIndex(where: { $0.type == "agentMessage" && $0.phase == nil }) {
                turns[index].items[last].phase = "final_answer"
            }
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
        for request in requests { resolveRequest(request.id, outcome: "終了（未回答）") }
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

    nonisolated static func pretty(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return string
    }
}
