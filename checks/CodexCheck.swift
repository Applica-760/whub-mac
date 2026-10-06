// Build/run from the repository root:
// swiftc -parse-as-library whub/Features/Codex/CodexClient.swift \
//   whub/Features/Codex/CodexStore.swift checks/CodexCheck.swift -o .build/codex-check
// .build/codex-check            # fixtures + local handshake, no inference
// .build/codex-check --live     # also uses the signed-in Codex account
import Foundation
import Darwin

@main
struct CodexCheck {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        var turn = CodexTurn(prompt: "fixture")
        turn.updateItem(["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "調査中"], completed: true)
        turn.updateItem(["id": "command", "type": "commandExecution", "command": "pwd", "status": "inProgress"], completed: false)
        turn.updateItem(["id": "command", "type": "commandExecution", "command": "pwd", "status": "completed", "aggregatedOutput": "/project\n"], completed: true)
        turn.updateItem(["id": "answer", "type": "agentMessage", "phase": "final_answer", "text": "日本語の回答 **完了**"], completed: true)
        assert(turn.history.count == 2)
        assert(turn.answers.count == 1)
        assert(turn.items.count == 3, "item completion must replace, not duplicate")
        assert(turn.history.last?.text == "/project\n")
        assert(turn.answers.first?.text.contains("日本語") == true)
        turn.updateItem(["id": "bad-command", "type": "commandExecution", "command": "false", "status": "failed", "aggregatedOutput": "failed"], completed: true)
        assert(turn.history.last?.status == "failed")
        let fixtureStore = CodexStore()
        fixtureStore.receive("item/commandExecution/requestApproval", params: ["command": "pwd"], requestID: 1)
        fixtureStore.receive("item/permissions/requestApproval", params: ["permissions": ["network": ["enabled": true]]], requestID: "1")
        assert(fixtureStore.requests.count == 2)
        assert(fixtureStore.requests[0].id != fixtureStore.requests[1].id)
        fixtureStore.receive("serverRequest/resolved", params: ["requestId": 1], requestID: nil)
        assert(fixtureStore.requests.count == 1)
        fixtureStore.receive("serverRequest/resolved", params: ["requestId": "1"], requestID: nil)
        assert(fixtureStore.requests.isEmpty)
        print("PASS: answer/history separation, item replacement, Unicode, failed command, approval routing")

        let client = CodexClient()
        try await client.connect()
        let account = try await client.request("account/read")
        print("PASS: initialize + account/read (account present: \(account["account"] is [String: Any]))")
        do {
            _ = try await client.request("whub/unsupported")
            assertionFailure("unknown RPC method must fail")
        } catch { print("PASS: RPC errors reach the caller") }
        client.disconnect()
        try await client.connect()
        _ = try await client.request("account/read")
        client.disconnect()
        print("PASS: disconnect + reconnect")

        guard CommandLine.arguments.contains("--live") else { return }
        let store = CodexStore()
        store.directory = FileManager.default.currentDirectoryPath
        store.draft = "UI接続テストです。ファイルの閲覧・編集やWeb検索はしないでください。シェルで pwd を1回実行し、その後、最終回答に日本語で『接続成功』と書いてください。"
        await store.send()
        let deadline = Date().addingTimeInterval(150)
        while store.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard !store.isBusy, store.turns.last?.status == "completed" else {
            store.disconnect()
            throw CodexError(message: store.errorMessage ?? "Live turn timed out or failed")
        }
        assert(store.turns.last?.answers.isEmpty == false, "live answer must be visible")
        print("PASS: live turn completed (\(store.turns.last?.history.count ?? 0) history items, \(store.turns.last?.answers.count ?? 0) answers)")
        store.draft = "接続テストを継続します。ツールは使わず『継続成功』とだけ答えてください。"
        await store.send()
        if let error = store.errorMessage { print("Follow-up error: " + error) }
        await store.interrupt()
        let stopDeadline = Date().addingTimeInterval(20)
        while store.isBusy && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(100)) }
        assert(!store.isBusy, "interrupt must unlock composer")
        assert(store.requests.isEmpty)
        if let error = store.errorMessage { print("Interrupt error: " + error) }
        guard ["interrupted", "completed"].contains(store.turns.last?.status ?? "") else {
            store.disconnect()
            throw CodexError(message: store.errorMessage ?? "Unexpected interrupt status")
        }
        print("PASS: follow-up turn + interrupt (\(store.turns.last?.status ?? "unknown"))")
        store.disconnect()
    }
}
