import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct AgentStoreTests {
    @Test func additionalInputsPreserveTypedContentAndOutputPosition() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, session: backend)
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        await store.send([.text(" first ")])
        backend.emit(.output(.message(AgentMessage(id: "p", role: .progress, title: "Progress", content: .text("working"), status: .running))))
        #expect(await testEventually { store.exchanges.first?.outputs.count == 1 })
        let skill = AgentSkill(id: "/review", name: "review", description: "")
        let input: [AgentInput] = [.text(" more "), .image(AgentImageAttachment(image: try testImage())), .skill(skill)]
        #expect(await store.sendAdditionalInput(input))
        let additional = try #require(store.exchanges.first?.additionalInputs.first)
        #expect(additional.outputIndex == 1)
        #expect(additional.input[0] == .text("more"))
        #expect(additional.input == backend.additional.first)
        #expect(store.exchanges.count == 1 && backend.sent == [[.text("first")]])
    }

    @Test(arguments: [false, true])
    func failedOrCompletedSteeringDoesNotAppendInput(completesDuringRequest: Bool) async {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, session: backend)
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
        let store = AgentStore(kind: .codex, session: backend)
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
        let store = AgentStore(kind: .codex, session: backend)
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
        await store.respond(to: "one", with: .approval(allow: true))
        await store.respond(to: "one", with: .approval(allow: false))
        #expect(backend.responses == ["one"])
        var resolved = first
        resolved.outcome = .accepted
        backend.emit(.output(.request(resolved)))
        #expect(await testEventually { store.respondingRequestIDs.isEmpty })
        #expect(store.exchanges.first?.pendingRequests.map(\.id) == ["two"])
        #expect(store.exchanges.first?.outputs.count == 2)
        await store.respond(to: "two", with: .answers(["q": "answer"]))
        #expect(backend.responses == ["one", "two"])
    }

    @Test func interruptionRestoresSubmittedInputButKeepsNewDraft() async {
        for hasNewDraft in [false, true] {
            let backend = TestAgentSession()
            let store = AgentStore(kind: .codex, session: backend)
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

    @Test func streamEndingFailsActiveWorkAndClosedStoreIgnoresLateEvents() async {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, session: backend)
        await store.connect(directory: "/project")
        await store.send([.text("submitted")])
        backend.finish()
        #expect(await testEventually { store.isClosed })
        #expect(!store.isBusy && !store.isConnected)
        #expect(store.exchanges.first?.status == .failed)
        #expect(store.draft == [.text("submitted")])
        backend.emit(.completed)
        #expect(store.exchanges.first?.status == .failed)
    }

    @Test func resumeUsesOriginalDirectoryAndRejectsRunningSnapshot() async {
        for invalid in [false, true] {
            let backend = TestAgentSession()
            backend.resumeAction = { entry in
                var exchange = testExchange()
                if invalid { exchange.status = .running }
                return AgentHistorySnapshot(entry: entry, exchanges: [exchange], selectedModelOption: nil)
            }
            let store = AgentStore(kind: .codex, session: backend)
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
