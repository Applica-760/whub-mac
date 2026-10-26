// テスト一覧:
// - additionalInputsPreserveTypedContentAndOutputPosition(): 追加入力の内容と出力位置を保持する。
// - failedOrCompletedSteeringDoesNotAppendInput(): 失敗・完了後の追加入力を記録しない。
// - concurrentSteeringAndStoppingAreBlocked(): 追加入力の重複と停止中の送信を拒否する。
// - outputsReplaceByIDAndRequestsResolveIndependently(): 回答処理中・回答済みの再送を拒否し、要求を個別に解決する。
// - interruptionRestoresSubmittedInputButKeepsNewDraft(): 中断時に送信内容を復元し、新しい下書きを保持する。
// - streamEndingFailsActiveWorkAndPreservesFinishedWork(): ストリーム終了で作業中は失敗、完了・中断済みは保持する。
// - explicitSessionCloseInterruptsActiveWork(): 明示的なセッション終了は作業を中断する。
// - resumeUsesOriginalDirectoryAndRejectsRunningSnapshot(): 元ディレクトリで履歴を再開し、実行中の履歴を拒否する。

import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

@Suite @MainActor
struct AgentStoreTests {
    @Test func additionalInputsPreserveTypedContentAndOutputPosition() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text(" first ")])
        backend.emit(.output(.message(WhubAgent.AgentMessage(id: "p", role: .progress, title: "Progress", content: .text("working"), status: .running))))
        #expect(await testEventually { store.exchanges.first?.outputs.count == 1 })
        let skill = AgentSkill(id: "/review", name: "review", description: "")
        let input: [whub.AgentInput] = [.text(" more "), .image(whub.AgentImageAttachment(image: try testImage())), .skill(skill)]
        #expect(await store.sendAdditionalInput(input))
        let additional = try #require(store.exchanges.first?.additionalInputs.first)
        #expect(additional.outputIndex == 1)
        #expect(additional.input[0] == .text("more"))
        #expect(try AgentModelMapping().input(additional.input) == backend.additional.first)
        #expect(store.exchanges.count == 1 && backend.sent == [[.text("first")]])
    }

    @Test(arguments: [false, true])
    func failedOrCompletedSteeringDoesNotAppendInput(completesDuringRequest: Bool) async {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text("first")])
        backend.additionalAction = { _ in
            if completesDuringRequest {
                backend.emit(.completed)
                #expect(await testEventually { !store.isBusy })
            }
            throw CodexAgentError(message: "rejected")
        }
        store.draft = [.text("new edits")]
        #expect(await store.sendAdditionalInput([.text("more")]) == false)
        #expect(store.exchanges.first?.additionalInputs.isEmpty == true)
        #expect(store.draft == [.text("new edits")])
        if completesDuringRequest { #expect(store.exchanges.first?.status == .completed) }
    }

    @Test func concurrentSteeringAndStoppingAreBlocked() async {
        let backend = TestAgentSession()
        var reply: CheckedContinuation<Void, Never>?
        backend.additionalAction = { _ in await withCheckedContinuation { reply = $0 } }
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text("first")])
        let sending = Task { await store.sendAdditionalInput([.text("more")]) }
        #expect(await testEventually { reply != nil })
        #expect(await store.sendAdditionalInput([.text("duplicate")]) == false)
        #expect(backend.additional.count == 1)
        reply?.resume()
        #expect(await sending.value)
        await store.interrupt()
        #expect(store.isStopping && backend.interrupts == 1)
        #expect(await store.sendAdditionalInput([.text("late")]) == false)
    }

    @Test func outputsReplaceByIDAndRequestsResolveIndependently() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text("first")])
        let first = AgentRequest(id: "one", kind: .approval(AgentApprovalRequest(reason: nil, command: "ls", directory: nil, changePreview: nil, permissionsDescription: nil, details: nil)))
        let second = AgentRequest(id: "two", kind: .questions([AgentQuestion(id: "q", prompt: "Which?", options: [], isSecret: false)]))
        backend.emit(.output(.request(first)))
        backend.emit(.output(.request(second)))
        #expect(await testEventually { store.exchanges.first?.pendingRequests.count == 2 })
        await store.respond(to: "two", with: .answers([:]))
        #expect(backend.responses.isEmpty)
        var releaseResponse: CheckedContinuation<Void, Never>?
        backend.respondAction = { id, _ in
            if id == "one" {
                await withCheckedContinuation { releaseResponse = $0 }
            }
            var resolved = id == "one" ? first : second
            resolved.outcome = id == "one" ? .accepted : .answered
            backend.emit(.output(.request(resolved)))
        }
        let responding = Task { await store.respond(to: "one", with: .approval(allow: true)) }
        defer { releaseResponse?.resume(); responding.cancel() }
        try #require(await testEventually { releaseResponse != nil && store.respondingRequestIDs.contains("one") })

        await store.respond(to: "one", with: .approval(allow: false))
        #expect(backend.responses == ["one"])
        releaseResponse?.resume()
        releaseResponse = nil
        await responding.value
        try #require(await testEventually {
            store.respondingRequestIDs.isEmpty && store.exchanges.first?.pendingRequests.map(\.id) == ["two"]
        })
        #expect(store.exchanges.first?.outputs.count == 2)
        await store.respond(to: "one", with: .approval(allow: false))
        #expect(backend.responses == ["one"])
        await store.respond(to: "two", with: .answers(["q": "answer"]))
        #expect(backend.responses == ["one", "two"])
        #expect(await testEventually { store.exchanges.first?.pendingRequests.isEmpty == true })
    }

    @Test func interruptionRestoresSubmittedInputButKeepsNewDraft() async {
        for hasNewDraft in [false, true] {
            let backend = TestAgentSession()
            let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
            await store.connect(directory: "/project")
            await store.send([.text("submitted")])
            if hasNewDraft { store.draft = [.text("new draft")] }
            backend.emit(.interrupted)
            #expect(await testEventually { !store.isBusy })
            #expect(store.exchanges.first?.status == .interrupted)
            #expect(store.draft == [.text(hasNewDraft ? "new draft" : "submitted")])
            store.disconnect()
        }
    }

    @Test(arguments: [WhubAgent.AgentExecutionStatus.running, .completed, .interrupted])
    func streamEndingFailsActiveWorkAndPreservesFinishedWork(status: WhubAgent.AgentExecutionStatus) async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text("submitted")])
        if status == .completed { backend.emit(.completed) }
        if status == .interrupted { backend.emit(.interrupted) }
        try #require(await testEventually { store.exchanges.first?.status == status })

        backend.finish()

        try #require(await testEventually { store.isClosed })
        #expect(!store.isBusy && !store.isConnected)
        #expect(store.exchanges.first?.status == (status == .running ? .failed : status))
        #expect(store.draft == (status == .completed ? [] : [.text("submitted")]))
    }

    @Test func explicitSessionCloseInterruptsActiveWork() async throws {
        let backend = TestAgentSession()
        let session = AgentSession(directory: "/project", adapter: backend)
        defer { session.close() }
        _ = try session.execute(AgentCommand(action: .send([.text("submitted")])))
        try #require(await testEventually { session.state.commands.first?.status == .completed })

        session.close()

        #expect(session.state.isClosed && backend.isClosed)
        #expect(session.state.exchanges.first?.status == .interrupted)
    }

    @Test func resumeUsesOriginalDirectoryAndRejectsRunningSnapshot() async {
        for invalid in [false, true] {
            let backend = TestAgentSession()
            backend.resumeAction = { entry in
                var exchange = WhubAgent.AgentExchange(input: [.text("Question")])
                exchange.status = .completed
                if invalid { exchange.status = .running }
                return AgentHistorySnapshot(entry: entry, exchanges: [exchange], selectedModelOption: nil)
            }
            let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
            let entry = testHistoryEntry(directory: "/original")
            #expect(await store.resume(entry) == !invalid)
            #expect(backend.directories == ["/original"])
            #expect(store.exchanges.count == (invalid ? 0 : 1))
            #expect(store.isClosed == invalid)
            if !invalid { #expect(store.conversationID == entry.id) }
            store.disconnect()
        }
    }
}
