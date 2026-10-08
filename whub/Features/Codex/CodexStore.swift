import Combine
import Foundation

struct CodexItem: Identifiable {
    let id: String
    var type: String
    var phase: String?
    var title: String
    var text: String
    var status: String
    var isAnswer: Bool { type == "agentMessage" && phase == "final_answer" }
}

struct CodexTurn: Identifiable {
    let id = UUID()
    var remoteID: String?
    let prompt: String
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

@MainActor
final class CodexStore: ObservableObject {
    @Published var draft = ""
    @Published var directory = ""
    @Published var writable = false
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
    private(set) var threadID: String?
    private let client = CodexClient()
    private var stopRequested = false
    private var needsResume = false

    init() {
        client.onEvent = { [weak self] in self?.receive($0, params: $1, requestID: $2) }
        client.onDisconnect = { [weak self] message in
            self?.fail(message)
            self?.needsResume = true
        }
    }

    var canSend: Bool { !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !directory.isEmpty }
    var canConfigure: Bool { threadID == nil && !isBusy }

    func loadSkills(forceReload: Bool = false) async {
        let cwd = directory
        guard !cwd.isEmpty else { return }
        isLoadingSkills = true
        if skillsDirectory != cwd { skills = [] }
        skillError = nil
        defer { if directory == cwd { isLoadingSkills = false } }
        do {
            try await client.connect()
            let result = try await client.request("skills/list", ["cwds": [cwd], "forceReload": forceReload])
            guard directory == cwd else { return }
            let entries = result["data"] as? [[String: Any]] ?? []
            skills = entries.flatMap { $0["skills"] as? [[String: Any]] ?? [] }.compactMap {
                guard $0["enabled"] as? Bool != false,
                      let name = $0["name"] as? String, let path = $0["path"] as? String else { return nil }
                return CodexSkill(name: name, description: $0["description"] as? String ?? "", path: path)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            skillsDirectory = cwd
            let errors = entries.flatMap { $0["errors"] as? [[String: Any]] ?? [] }
            if !errors.isEmpty { skillError = Self.pretty(errors) }
        } catch {
            if directory == cwd { skillError = error.localizedDescription }
        }
    }

    func send(skills selectedSkills: [CodexSkill] = []) async {
        guard canSend else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "作業フォルダが存在しません。フォルダを選択してください。"
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        errorMessage = nil
        stopRequested = false
        isBusy = true
        turns.append(CodexTurn(prompt: prompt))
        do {
            try await client.connect()
            if threadID == nil {
                let result = try await client.request("thread/start", [
                    "cwd": directory, "sandbox": writable ? "workspace-write" : "read-only",
                    "approvalPolicy": "on-request", "approvalsReviewer": "user"
                ])
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
            var input: [[String: Any]] = [["type": "text", "text": prompt]]
            input += selectedSkills.map { ["type": "skill", "name": $0.name, "path": $0.path] }
            let result = try await client.request("turn/start", ["threadId": threadID, "input": input])
            if let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, isBusy {
                turns[turns.count - 1].remoteID = id
                if stopRequested { await interrupt() }
            }
        } catch {
            fail(error.localizedDescription)
            if draft.isEmpty { draft = prompt }
        }
    }

    func interrupt() async {
        guard isBusy else { return }
        stopRequested = true
        isStopping = true
        guard let threadID, let turnID = turns.last?.remoteID else { return }
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
        guard !isBusy else { return }
        client.disconnect()
        threadID = nil
        needsResume = false
        turns = []
        requests = []
        errorMessage = nil
        model = "Codexの既存設定"
    }

    func disconnect() { client.disconnect() }

    func answer(_ request: CodexRequest, result: [String: Any]) {
        do {
            try client.respond(id: request.rpcID, result: result)
            requests.removeAll { $0.id == request.id }
        } catch { fail(error.localizedDescription) }
    }

    func receive(_ method: String, params: [String: Any], requestID: Any?) {
        if let requestID {
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput"].contains(method) {
                var details = params
                if method == "item/fileChange/requestApproval",
                   let item = turns.last?.items.first(where: { $0.id == params["itemId"] as? String }) {
                    details["changePreview"] = item.text
                }
                requests.append(CodexRequest(rpcID: requestID, method: method, params: details))
            } else {
                do { try client.rejectUnsupported(id: requestID) } catch { fail(error.localizedDescription) }
                errorMessage = "このMVPでは未対応の要求です: \(method)。要求は許可していません。"
            }
            return
        }
        if method == "serverRequest/resolved", let id = params["requestId"] {
            requests.removeAll { $0.id == Self.pretty(id) }
            return
        }
        guard params["threadId"] as? String == threadID, !turns.isEmpty else { return }
        let index = turns.count - 1
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
        if !turns.isEmpty { turns[turns.count - 1].status = status }
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
