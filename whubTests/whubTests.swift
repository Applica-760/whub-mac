import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@MainActor
func testEventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

func testHistoryEntry(_ id: String = "thread-1", directory: String = FileManager.default.currentDirectoryPath) -> AgentHistoryEntry {
    AgentHistoryEntry(id: id, name: "History", preview: "Preview", directory: directory, updatedAt: Date(timeIntervalSince1970: 123))
}

@MainActor
func testImage() throws -> NSImage {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.addRepresentation(bitmap)
    return image
}

@MainActor
func testExchange(_ prompt: String = "Question", answer: String = "Answer") -> AgentExchange {
    var exchange = AgentExchange(input: [.text(prompt)])
    exchange.outputs = [.message(AgentMessage(id: "answer", role: .answer, title: "Answer", content: .markdown(answer), status: .completed))]
    exchange.status = .completed
    return exchange
}

@MainActor
final class TestAgentSession: AgentSession {
    let kind = AgentKind.codex
    let events: AsyncStream<AgentEvent>
    private let emitter: AsyncStream<AgentEvent>.Continuation
    var sent: [[AgentInput]] = []
    var additional: [[AgentInput]] = []
    var changedOptions: [AgentModelOption] = []
    var responses: [String] = []
    var directories: [String] = []
    var interrupts = 0
    var isClosed = false
    var options: [AgentModelOption] = []
    var skills: [AgentSkill] = []
    var status: [AgentContent] = [.code("Status")]
    var sendAction: ([AgentInput]) async throws -> Void = { _ in }
    var additionalAction: ([AgentInput]) async throws -> Void = { _ in }
    var changeModelAction: (AgentModelOption) async throws -> Void = { _ in }
    var respondAction: (String, AgentResponse) async throws -> Void = { _, _ in }
    var historyAction: (String?) async throws -> AgentHistoryPage = { _ in AgentHistoryPage(entries: [], nextCursor: nil) }
    var resumeAction: (AgentHistoryEntry) async throws -> AgentHistorySnapshot = {
        AgentHistorySnapshot(entry: $0, exchanges: [testExchange()], selectedModelOption: nil)
    }
    init() {
        let stream = AsyncStream<AgentEvent>.makeStream()
        events = stream.stream
        emitter = stream.continuation
    }
    func emit(_ event: AgentEvent) { emitter.yield(event) }
    func finish() { emitter.finish() }
    func connect(directory: String) async throws { directories.append(directory) }
    func send(_ input: [AgentInput]) async throws { sent.append(input); try await sendAction(input) }
    func sendAdditionalInput(_ input: [AgentInput]) async throws { additional.append(input); try await additionalAction(input) }
    func interrupt() async throws { interrupts += 1 }
    func loadModelOptions() async throws -> [AgentModelOption] { options }
    func loadSkills() async throws -> [AgentSkill] { skills }
    func loadStatus() async throws -> [AgentContent] { status }
    func changeModel(_ option: AgentModelOption) async throws { changedOptions.append(option); try await changeModelAction(option) }
    func respond(to requestID: String, with response: AgentResponse) async throws {
        responses.append(requestID)
        try await respondAction(requestID, response)
    }
    func loadHistory(cursor: String?) async throws -> AgentHistoryPage { try await historyAction(cursor) }
    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot { try await resumeAction(entry) }
    func disconnect() { isClosed = true; emitter.finish() }
}

@Suite @MainActor
struct CodexAgentReceivingTests {
    @Test func fragmentedJSONKeepsUnicodeEmptyLinesAndMultipleMessages() throws {
        let messages: [[String: Any]] = [["id": 1, "text": String(repeating: "日本語👩‍💻", count: 2000)], ["id": 2, "text": "second"]]
        var bytes = Data([10])
        for message in messages {
            bytes.append(try JSONSerialization.data(withJSONObject: message))
            bytes.append(contentsOf: [10, 10])
        }
        for size in [1, 127, bytes.count] {
            var buffer = CodexAgentClient.LineBuffer()
            var received: [[String: Any]] = []
            for start in stride(from: 0, to: bytes.count, by: size) {
                try buffer.append(Data(bytes[start..<min(start + size, bytes.count)])) {
                    received.append(try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]))
                }
            }
            #expect(received.count == messages.count)
            for (actual, expected) in zip(received, messages) {
                #expect(actual["id"] as? Int == expected["id"] as? Int)
                #expect(actual["text"] as? String == expected["text"] as? String)
            }
        }
    }

    @Test func unterminatedLineWaitsAndMalformedJSONThrows() throws {
        var buffer = CodexAgentClient.LineBuffer()
        var received: [Data] = []
        buffer.append(Data("{\"id\":1}".utf8)) { received.append($0) }
        #expect(received.isEmpty)
        buffer.append(Data("\n".utf8)) { received.append($0) }
        #expect(received == [Data("{\"id\":1}".utf8)])
        #expect(throws: (any Error).self) {
            try buffer.append(Data("invalid\n".utf8)) { _ = try JSONSerialization.jsonObject(with: $0) }
        }
    }

    @Test func streamedItemsRetainDeltasUntilFinalTextAndInferOnlyLastAnswer() throws {
        var turn = CodexAgentTurn()
        turn.updateItem(["id": "a", "type": "agentMessage", "phase": "commentary", "text": "progress"], completed: true)
        turn.updateItem(["id": "b", "type": "agentMessage"], completed: false)
        turn.items[1].delta = "stream"
        turn.updateItem(["id": "b", "type": "agentMessage"], completed: true)
        #expect(turn.items[1].delta == "stream")
        turn.inferFinalAnswerIfNeeded()
        #expect(turn.answers.map(\.id) == ["b"])
        turn.updateItem(["id": "b", "type": "agentMessage", "phase": "final_answer", "text": "final"], completed: true)
        #expect(turn.items[1].delta.isEmpty && turn.items[1].text == "final")
        turn.updateItem(["id": "reason", "type": "reasoning"], completed: true)
        #expect(turn.items.count == 2)
    }

    @Test func liveSessionSteersImagesAndSkillsWithoutStartingAnotherTurn() async throws {
        var calls: [String] = []
        var steer: [String: Any] = [:]
        let session = CodexAgentSession(request: { method, params, _ in
            calls.append(method)
            switch method {
            case "thread/start": return ["thread": ["id": "thread-1"]]
            case "turn/start": return ["turn": ["id": "turn-1"]]
            case "turn/steer": steer = params; return ["turnId": "turn-1"]
            case "skills/list": return ["data": [["skills": [["name": "review", "path": "/skills/review"]]]]]
            default: throw CodexAgentError(message: method)
            }
        })
        defer { session.disconnect() }
        try await session.connect(directory: FileManager.default.currentDirectoryPath)
        let skill = try #require(try await session.loadSkills().first)
        try await session.send([.text("first")])
        try await session.sendAdditionalInput([.text("more"), .image(AgentImageAttachment(image: try testImage())), .skill(skill)])
        #expect(calls.filter { $0 == "turn/start" }.count == 1)
        #expect(steer["expectedTurnId"] as? String == "turn-1")
        let inputs = try #require(steer["input"] as? [[String: Any]])
        #expect(inputs.map { $0["type"] as? String } == ["text", "image", "skill"])
        #expect((inputs[1]["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(inputs[2]["path"] as? String == "/skills/review")
    }

    @Test func foreignThreadEventsAreIgnoredAndCompletedTurnCannotBeSteered() async throws {
        let session = CodexAgentSession(request: { method, _, _ in
            method == "thread/start" ? ["thread": ["id": "thread-1"]] : ["turn": ["id": "turn-1"]]
        })
        let store = AgentStore(kind: .codex, session: session)
        defer { store.disconnect() }
        await store.connect(directory: FileManager.default.currentDirectoryPath)
        await store.send([.text("first")])
        session.receive("item/completed", params: ["threadId": "other", "item": ["id": "wrong", "type": "agentMessage", "text": "wrong"]], requestID: nil)
        session.receive("item/completed", params: ["threadId": "thread-1", "turnId": "turn-1", "item": ["id": "answer", "type": "agentMessage", "text": "answer"]], requestID: nil)
        session.receive("turn/completed", params: ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]], requestID: nil)
        #expect(await testEventually { !store.isBusy })
        #expect(store.exchanges.first?.outputs.map(\.id) == ["answer"])
        #expect(store.exchanges.first?.answers.count == 1)
        await #expect(throws: CodexAgentError.self) { try await session.sendAdditionalInput([.text("late")]) }
    }
}

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

@Suite @MainActor
struct CodexAgentHistoryAndRequestTests {
    @Test func historyKeepsAdditionalInputsImagesAndCommentaryOrdering() throws {
        let image = try #require(try testImage().tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: image))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let turns: [[String: Any]] = [["id": "turn-1", "status": "completed", "items": [
            ["id": "u1", "type": "userMessage", "content": [["type": "text", "text": "first"]]],
            ["id": "p", "type": "agentMessage", "phase": "commentary", "text": "progress"],
            ["id": "u2", "type": "userMessage", "content": [["type": "skill", "name": "review", "path": "/review"],
                ["type": "image", "url": "data:image/png;base64," + png.base64EncodedString()]]],
            ["id": "a", "type": "agentMessage", "text": "legacy answer"]
        ]]]
        let exchange = try #require(CodexAgentMapping.exchanges(turns).first)
        #expect(exchange.input == [.text("first")])
        #expect(exchange.additionalInputs.first?.outputIndex == 1)
        #expect(exchange.additionalInputs.first?.input.count == 2)
        #expect(exchange.answers.map(\.id) == ["a"])
        #expect(exchange.history.map(\.id) == ["p"])
        #expect(exchange.status == .completed)
    }

    @Test func invalidOrIncompleteHistoryIsRejected() {
        for bad: [String: Any] in [[:], ["id": "t", "status": "inProgress", "items": []],
            ["id": "t", "status": "completed", "itemsView": "summary", "items": []],
            ["id": "t", "status": "completed", "items": [["id": "u", "type": "userMessage", "content": [["type": "unknown"]]]]],
            ["id": "t", "status": "completed", "items": [["type": "agentMessage"]]]] {
            #expect(throws: CodexAgentError.self) { try CodexAgentMapping.exchanges([bad]) }
        }
        #expect(throws: CodexAgentError.self) { try CodexAgentMapping.historyEntry(["id": "t", "cwd": "relative", "updatedAt": 1.0]) }
    }

    @Test func paginatedResumeReadsEveryTurnAndDoesNotInfer() async throws {
        var methods: [String] = []
        let entry = testHistoryEntry()
        let session = CodexAgentSession(request: { method, params, _ in
            methods.append(method)
            switch method {
            case "thread/read": return ["thread": ["id": entry.id, "historyMode": "paginated"]]
            case "thread/resume":
                #expect(params["excludeTurns"] as? Bool == true)
                return ["thread": ["id": entry.id], "cwd": entry.directory, "model": "m"]
            case "thread/turns/list":
                #expect(params["itemsView"] as? String == "full")
                let turn: [String: Any] = ["id": params["cursor"] == nil ? "one" : "two", "status": "completed", "items": [[String: Any]]()]
                if params["cursor"] == nil { return ["data": [turn], "nextCursor": "next"] }
                #expect(params["cursor"] as? String == "next")
                return ["data": [turn]]
            default: throw CodexAgentError(message: method)
            }
        })
        defer { session.disconnect() }
        try await session.connect(directory: entry.directory)
        let snapshot = try await session.resume(entry)
        #expect(snapshot.exchanges.count == 2)
        #expect(methods == ["thread/read", "thread/resume", "thread/turns/list", "thread/turns/list"])
    }

    @Test func questionsAndApprovalsKeepProtocolSpecificResponses() throws {
        let approval = try CodexAgentMapping.request(method: "item/permissions/requestApproval", params: ["permissions": ["network": true]], rpcID: "rpc")
        let allowed = try CodexAgentMapping.response(.approval(allow: true), to: approval, method: "item/permissions/requestApproval", params: ["permissions": ["network": true]])
        #expect((allowed.result["permissions"] as? [String: Bool])?["network"] == true)
        let denied = try CodexAgentMapping.response(.approval(allow: false), to: approval, method: "item/permissions/requestApproval", params: [:])
        #expect((denied.result["permissions"] as? [String: Any])?.isEmpty == true)
        let question = try CodexAgentMapping.request(method: "item/tool/requestUserInput", params: ["questions": [["id": "q", "question": "Which?", "isSecret": true]]], rpcID: 2)
        #expect(throws: CodexAgentError.self) { try CodexAgentMapping.response(.answers([:]), to: question, method: "item/tool/requestUserInput", params: [:]) }
        let answered = try CodexAgentMapping.response(.answers(["q": "yes"]), to: question, method: "item/tool/requestUserInput", params: [:])
        #expect((answered.result["answers"] as? [String: [String: [String]]])?["q"]?["answers"] == ["yes"])
        #expect(throws: CodexAgentError.self) { try CodexAgentMapping.request(method: "unknown", params: [:], rpcID: 3) }
        #expect(throws: CodexAgentError.self) { try CodexAgentMapping.response(.approval(allow: true), to: question, method: "item/tool/requestUserInput", params: [:]) }
    }

    @Test func skillFilteringAndHistoryPaginationUseCommonTypes() async throws {
        let session = CodexAgentSession(request: { method, _, _ in
            if method == "skills/list" { return ["data": [["skills": [["name": "visible", "path": "/skill"], ["name": "hidden", "path": "/hidden", "enabled": false]]]]] }
            return ["data": [["id": "t", "cwd": "/project", "updatedAt": 1.0]], "nextCursor": "next"]
        })
        defer { session.disconnect() }
        try await session.connect(directory: FileManager.default.currentDirectoryPath)
        #expect(try await session.loadSkills().map(\.name) == ["visible"])
        let history = try await session.loadHistory(cursor: nil)
        #expect(history.entries.map(\.id) == ["t"] && history.nextCursor == "next")
    }
}

@Suite @MainActor
struct AgentBookTabTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func notificationsFollowTabsAcrossReorderingAndRemoval() async throws {
        let context = try container()
        var backends: [TestAgentSession] = []
        var sounds: [String] = []
        let book = AgentBookStore(context: context.mainContext, makeSession: { _ in
            let session = TestAgentSession(); backends.append(session); return session
        }, notify: { sounds.append($0) })
        defer { book.disconnect() }
        for _ in 0..<6 { book.add() }
        let ids = book.tabs.map(\.id)
        for index in [1, 3] {
            await book.tabs[index].store.connect(directory: "/project")
            await book.tabs[index].store.send([.text("work")])
            backends[index].emit(.completed)
        }
        #expect(await testEventually { book.completedTabIDs == [ids[1], ids[3]] })
        #expect(sounds == ["Glass", "Glass"])
        book.move(ids[3], before: ids[0])
        #expect(book.completedTabIDs == [ids[1], ids[3]])
        let visible = AgentBookTabButton.visibleRange(count: book.tabs.count, selectedIndex: 6)
        #expect(visible.count == 5 && visible.contains(6))
        book.select(ids[1])
        #expect(book.completedTabIDs == [ids[3]])
        book.remove(ids[3])
        backends[3].emit(.completed)
        #expect(!book.completedTabIDs.contains(ids[3]) && backends[3].isClosed)
    }

    @Test func newConversationReplacesOnlyItsOwnStateAndLastTabRemains() async throws {
        let context = try container()
        var backends: [TestAgentSession] = []
        let book = AgentBookStore(context: context.mainContext, makeSession: { _ in
            let session = TestAgentSession(); backends.append(session); return session
        }, notify: { _ in })
        defer { book.disconnect() }
        let first = book.selectedTab
        first.store.draft = [.text("draft")]
        book.add()
        let second = book.selectedTab
        second.store.draft = [.text("keep")]
        #expect(book.newConversation(in: first.id))
        #expect(backends[0].isClosed && book.tabs[0].id != first.id)
        #expect(book.tabs[0].store.draft.isEmpty && second.store.draft == [.text("keep")])
        book.remove(second.id)
        let remaining = book.selectedTabID
        book.remove(remaining)
        #expect(book.tabs.count == 1 && book.selectedTabID != remaining)
    }

    @Test func successfulResumeReplacesSourceInPlaceAndReusesExistingConversation() async throws {
        let context = try container()
        let book = AgentBookStore(context: context.mainContext, makeSession: { _ in TestAgentSession() }, notify: { _ in })
        defer { book.disconnect() }
        let source = book.selectedTab
        source.store.draft = [.text("discard after success")]
        let entry = testHistoryEntry()
        #expect(await book.resume(entry, replacing: source.id))
        #expect(book.tabs.count == 1 && source.store.isClosed)
        let resumed = book.selectedTab
        #expect(resumed.store.conversationID == entry.id && resumed.store.exchanges.count == 1)
        book.add()
        let empty = book.selectedTabID
        #expect(await book.resume(entry, replacing: empty))
        #expect(book.tabs.count == 1 && book.selectedTabID == resumed.id)
    }

    @Test func failedOrCancelledResumeDoesNotReplaceSource() async throws {
        let context = try container()
        var reply: CheckedContinuation<AgentHistorySnapshot, Error>?
        let entry = testHistoryEntry()
        let failedBook = AgentBookStore(context: context.mainContext, makeSession: { _ in
            let session = TestAgentSession()
            session.resumeAction = { _ in throw CodexAgentError(message: "failed") }
            return session
        }, notify: { _ in })
        defer { failedBook.disconnect() }
        let failedSource = failedBook.selectedTab
        failedSource.store.draft = [.text("keep")]
        #expect(await failedBook.resume(entry, replacing: failedSource.id) == false)
        #expect(failedBook.selectedTabID == failedSource.id && failedSource.store.draft == [.text("keep")])
        let pendingBook = AgentBookStore(context: context.mainContext, makeSession: { _ in
            let session = TestAgentSession()
            session.resumeAction = { _ in try await withCheckedThrowingContinuation { reply = $0 } }
            return session
        }, notify: { _ in })
        defer { pendingBook.disconnect() }
        let original = pendingBook.selectedTabID
        let loading = Task { await pendingBook.resume(entry, replacing: original) }
        #expect(await testEventually { reply != nil })
        pendingBook.remove(original)
        reply?.resume(returning: AgentHistorySnapshot(entry: entry, exchanges: [], selectedModelOption: nil))
        #expect(await loading.value == false)
        #expect(pendingBook.tabs.count == 1 && pendingBook.selectedTabID != original)
    }

    @Test func busyTabCannotResumeOrResetAndKindChangePreservesDraft() async throws {
        let context = try container()
        let backend = TestAgentSession()
        let book = AgentBookStore(context: context.mainContext, makeSession: { _ in backend }, notify: { _ in })
        defer { book.disconnect() }
        let source = book.selectedTab
        source.store.draft = [.text("keep")]
        await source.store.connect(directory: "/project")
        await source.store.send([.text("running")])
        #expect(await book.resume(testHistoryEntry(), replacing: source.id) == false)
        #expect(!book.newConversation(in: source.id))
        #expect(!book.changeKind(.claudeCode, in: source.id))
        let fresh = AgentBookStore(context: context.mainContext, makeSession: { _ in nil }, notify: { _ in })
        defer { fresh.disconnect() }
        fresh.selectedTab.store.draft = [.text("draft")]
        #expect(fresh.changeKind(.claudeCode, in: fresh.selectedTabID))
        #expect(fresh.selectedTab.store.draft == [.text("draft")])
    }

    @Test func historyStoreDeduplicatesPagesAndPreservesEntriesOnFailure() async {
        let backend = TestAgentSession()
        var fail = false
        backend.historyAction = { cursor in
            if fail { throw CodexAgentError(message: "failed") }
            return AgentHistoryPage(entries: [testHistoryEntry("one"), testHistoryEntry(cursor == nil ? "one" : "two")], nextCursor: cursor == nil ? "next" : nil)
        }
        let history = AgentHistoryStore(session: backend)
        await history.load()
        #expect(history.entries.map(\.id) == ["one"])
        await history.load(more: true)
        #expect(history.entries.map(\.id) == ["one", "two"] && history.nextCursor == nil)
        fail = true
        await history.load()
        #expect(history.entries.count == 2 && history.errorMessage == "failed" && !history.isLoading)
    }
}

private final class AgentBookLayoutProbe: NSObject, NSLayoutManagerDelegate {
    var laidOutContainers: [NSTextContainer] = []

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        laidOutContainers.append(textContainer)
        return false
    }
}

@Suite(.serialized) @MainActor
struct AgentBookReadingTests {
    @Test func sessionViewsSurviveSwitchesAndClosedTabsAreRemoved() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try #require(window.contentView)
        let coordinator = RetainedPageContainer<Int, RetainedInputProbe>.Coordinator()
        var inputs: [Int: NSTextView] = [:]
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in
            AnyView(RetainedInputProbe { inputs[id] = $0 })
        }
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        let first = try #require(coordinator.pages[1])
        first.view.layoutSubtreeIfNeeded()
        let input = try #require(inputs[1])
        input.string = "draft"
        input.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(window.makeFirstResponder(input))

        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(first.view.isHidden)
        #expect(!first.activity.isActive.value)
        #expect(window.firstResponder !== input)
        let second = try #require(coordinator.pages[2])
        #expect(second.activity.isActive.value)

        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(coordinator.pages[1]?.view === first.view)
        #expect(coordinator.pages[2]?.view === second.view)
        #expect(!first.view.isHidden)
        #expect(first.activity.isActive.value)
        #expect(!second.activity.isActive.value)
        first.view.layoutSubtreeIfNeeded()
        #expect(inputs[1] === input)
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))

        coordinator.update(container, selection: 1, availablePages: [1], isActive: true, rootView: root)
        #expect(coordinator.pages.count == 1)
        #expect(second.view.superview == nil)
        #expect(!second.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === first.view)
    }

    @Test func hiddenFeatureDeactivatesItsRetainedSession() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = RetainedPageContainer<Int, Text>.Coordinator()
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in AnyView(Text("Session \(id)")) }
        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)
        let session = try #require(coordinator.pages[1])
        coordinator.update(container, selection: 1, availablePages: nil, isActive: false, rootView: root)
        #expect(!session.activity.isActive.value)
        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)
        #expect(session.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === session.view)
    }


    @Test func tailUpdateDoesNotLayOutUnchangedFrontPages() throws {
        let book = AgentBookPageLayout()
        let probe = AgentBookLayoutProbe()
        var exchanges = (0..<8).map { testExchange("Question \($0)", answer: String(repeating: "Paragraph \($0).\n\n", count: 12)) }
        let viewport = CGSize(width: 800, height: 450)
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .light)
        let first = try #require(book.pages.first)
        for page in book.pages { page.manager.delegate = probe }
        exchanges[7].outputs = testExchange(answer: "Updated final answer").outputs
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .light)
        #expect(!probe.laidOutContainers.isEmpty)
        #expect(!probe.laidOutContainers.contains { $0 === first.container })
        #expect(book.pages.first === first)
        let fresh = AgentBookPageLayout()
        fresh.update(exchanges, agentName: "Codex")
        fresh.prepare(viewport: viewport, colorScheme: .light)
        #expect(book.pages.map { $0.storage.string } == fresh.pages.map { $0.storage.string })
    }

    @Test func incrementalLayoutMatchesFreshLayoutAcrossEditsAndResize() throws {
        let book = AgentBookPageLayout()
        var exchanges = (0..<8).map { testExchange("Question \($0)", answer: String(repeating: "Paragraph \($0). 日本語の本文。\n\n", count: 12)) }
        var viewport = CGSize(width: 800, height: 450)
        var scheme = ColorScheme.light
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: scheme)
        let originalPages = book.pages
        #expect(originalPages.count == exchanges.count)
        for edit in 0..<6 {
            switch edit {
            case 0: exchanges[7].outputs = testExchange(answer: "Appended answer.\n\n```swift\nlet value = 1\n```").outputs
            case 1: exchanges[4].outputs = testExchange(answer: "Shortened middle answer").outputs
            case 2: exchanges.removeLast(3)
            case 3: exchanges.removeAll()
            case 4:
                exchanges = [testExchange("New conversation")]
                viewport = CGSize(width: 600, height: 320)
            default: scheme = .dark
            }
            book.update(exchanges, agentName: "Codex")
            #expect(book.prepare(viewport: viewport, colorScheme: scheme))
            let fresh = AgentBookPageLayout()
            fresh.update(exchanges, agentName: "Codex")
            fresh.prepare(viewport: viewport, colorScheme: scheme)
            #expect(book.pages.count == exchanges.count)
            #expect(book.pages.map { $0.storage.string } == fresh.pages.map { $0.storage.string })
            #expect(book.pages.flatMap(\.codes).map(\.text) == fresh.pages.flatMap(\.codes).map(\.text))
            #expect(book.headers.map(\.frame) == fresh.headers.map(\.frame))
            #expect(!book.prepare(viewport: viewport, colorScheme: scheme))
            if edit == 0 { #expect(zip(book.pages.prefix(3), originalPages.prefix(3)).allSatisfy { $0 === $1 }) }
        }
    }

    @Test func fixedPromptAreaKeepsAdditionalInputsAndAnswerOnOnePage() throws {
        let prompt = (1...80).map { "error line \($0)" }.joined(separator: "\n")
        var exchange = testExchange(prompt, answer: "before additional")
        exchange.additionalInputs = [AgentAdditionalInput(input: [.text("additional prompt")], outputIndex: 1)]
        exchange.outputs += [.message(AgentMessage(id: "second", role: .answer, title: "Answer", content: .text("after additional"), status: .completed))]
        let book = AgentBookPageLayout()
        let viewport = CGSize(width: 800, height: 450)
        book.update([exchange], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 1)
        let page = try #require(book.pages.first)
        let input = try #require(page.prompts.first)
        #expect(page.prompts.count == 1)
        #expect(input.text.string.contains(prompt))
        #expect(input.text.string.contains("additional prompt"))
        #expect(input.size.height == viewport.height * 0.15)
        #expect((input.text.string as NSString).range(of: prompt).location < (input.text.string as NSString).range(of: "additional prompt").location)
        #expect((page.storage.string as NSString).range(of: "before additional").location < (page.storage.string as NSString).range(of: "after additional").location)
        let short = AgentBookPageLayout()
        short.update([testExchange("short")], agentName: "Codex")
        short.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.headers.first?.frame.minY == short.headers.first?.frame.minY)
        exchange.outputs[1] = .message(AgentMessage(id: "second", role: .answer, title: "Answer", content: .text("updated"), status: .completed))
        book.update([exchange], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 1 && page.storage.string.contains("updated"))
        book.update([exchange, testExchange("Next input")], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 2)
        #expect(book.selectedPage == 1)
        #expect(book.pages[1].prompts.first?.text.string.contains("Next input") == true)
        book.selectPage(0)
        #expect(book.selectedPage == 0 && book.spread == 0)
        exchange.outputs = testExchange(answer: "Further answer update").outputs
        book.update([exchange, testExchange("Next input")], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.selectedPage == 0)
        book.selectPage(1)
        #expect(book.selectedPage == 1 && book.spread == 0)
        let third = testExchange("Third input")
        book.update([exchange, testExchange("Next input"), third], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.selectedPage == 2)
        book.move(-1)
        #expect(book.selectedPage == 0 && book.spread == 0)
        book.move(1)
        #expect(book.selectedPage == 2 && book.spread == 1)
        book.move(1)
        #expect(book.selectedPage == 2)
        book.update([], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.isEmpty)
    }

    @Test func imagesAndCodeRemainOrderedAcrossPagesAndAnswerUpdates() throws {
        let images = try (0..<3).map { _ in AgentImageAttachment(image: try testImage()) }
        var exchange = testExchange("What is shown?", answer: String(repeating: "paragraph\n\n", count: 30) + "```swift\n" + String(repeating: "let value = 1\n", count: 50) + "```")
        exchange.input += images.map(AgentInput.image)
        let book = AgentBookPageLayout()
        for scheme in [ColorScheme.light, .dark] {
            book.update([exchange], agentName: "Codex")
            book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: scheme)
            var found: [NSImage] = []
            let page = try #require(book.pages.first)
            let prompt = try #require(page.prompts.first)
            prompt.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: prompt.text.length)) { value, _, _ in
                if let image = (value as? NSTextAttachment)?.image { found.append(image) }
            }
            #expect(found.count == images.count)
            #expect(zip(found, images).allSatisfy { $0.0 === $0.1.image })
            #expect(page.codes.map(\.text).joined() == String(repeating: "let value = 1\n", count: 50))
            #expect(book.pages.count == 1)
        }
    }

    @Test func textReplacementKeepsReadingFocusAndSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let book = AgentBookPageLayout()
        var exchange = testExchange("first page", answer: "")
        book.update([exchange], agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame = content.bounds
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let focus = AgentBookFocus()
        focus.readingView = surface
        focus.activateReading()
        #expect(window.firstResponder === surface)
        let text = try #require(surface.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        exchange.outputs = testExchange(answer: "appended answer").outputs
        book.update([exchange], agentName: "Codex")
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(focus.isReading(in: window) && text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(book.pages.first?.storage.string.contains("appended answer") == true)
    }

    @Test func shrinkingPagesDoesNotStealInputFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let focus = AgentBookFocus()
        let book = AgentBookPageLayout()
        let exchanges = (0..<3).map { _ in testExchange(String(repeating: "長い本文。\n\n", count: 100)) }
        book.update(exchanges, agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame = content.bounds
        focus.readingView = surface
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let originalPages = surface.subviews.compactMap { $0 as? NSScrollView }
        try #require(originalPages.count == 2)
        let input = NSTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        focus.inputView = input
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.activateInput()
        book.update([testExchange("short")], agentName: "Codex")
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(surface.subviews.compactMap { $0 as? NSScrollView }.count == 1)
        #expect(originalPages.allSatisfy { $0.superview == nil })
        #expect(window.firstResponder === input && input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        surface.isHidden = true
        focus.activateReading()
        #expect(window.firstResponder === input)
    }

    @Test func copyingSelectionRestoresCodeAndFormulaSources() throws {
        let book = AgentBookPageLayout()
        let source = "Inline $x^2$\n\n```swift\nlet x = 1\n```"
        book.update([testExchange("Question", answer: source)], agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame.size = CGSize(width: 800, height: 450)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let text = try #require(surface.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first)
        text.setSelectedRange(NSRange(location: 0, length: try #require(book.pages.first).storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        #expect(text.writeSelection(to: pasteboard, type: .string))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("$x^2$") && copied.contains("let x = 1"))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test func markdownParserPreservesStructuredBlocks() throws {
        let blocks = AgentBookMarkdown(source: "# Heading\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet x = 1\n```\n").blocks
        try #require(blocks.count == 3)
        #expect(blocks.first?.kind == .header(level: 1))
        if case .table(let columns) = blocks[1].kind {
            #expect(columns.count == 2 && blocks[1].children.count == 2)
        } else { Issue.record("Markdown table was not preserved") }
        #expect(blocks.last?.kind == .codeBlock(languageHint: "swift"))
    }

    @Test func nativeInputAcceptsPNGAndTIFFAndSendsTypedDraft() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, session: backend)
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        let focus = AgentBookFocus()
        let root = AgentBookInputView(store: store, skillStore: AgentSkillStore(session: backend),
            historyStore: AgentHistoryStore(session: backend), focus: focus, agentName: "Codex",
            newConversation: {}, resume: { _ in false }).frame(width: 600, height: 160)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(await testEventually { focus.inputView != nil })
        let input = try #require(focus.inputView as? NSTextView)
        let image = try testImage()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        for (type, bytes) in [(NSPasteboard.PasteboardType.png, png), (.tiff, tiff)] {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.setData(bytes, forType: type)
            #expect(input.readSelection(from: pasteboard, type: type))
        }
        #expect(store.draft.agentBookImages.count == 2)
        store.draft.insert(.text("describe"), at: 0)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        input.keyDown(with: event)
        #expect(await testEventually { backend.sent.count == 1 })
        #expect(backend.sent.first?.agentBookImages.count == 2)
        #expect(backend.sent.first?.agentBookDraftText == "describe")
        #expect(store.draft.isEmpty)
    }

    @Test func completionTokenRequiresCommandPositionAndHandlesUnicode() {
        #expect(AgentBookInputToken.at(NSRange(location: 4, length: 0), in: "/res")?.text == "/res")
        #expect(AgentBookInputToken.at(NSRange(location: 8, length: 0), in: "text /re") == nil)
        let source = "日本語 $review"
        let end = (source as NSString).length
        #expect(AgentBookInputToken.at(NSRange(location: end, length: 0), in: source)?.text == "$review")
        #expect(AgentBookInputToken.at(NSRange(location: end, length: 1), in: source) == nil)
        #expect(AgentBookInputToken.at(NSRange(location: end + 1, length: 0), in: source) == nil)
    }

    @Test func approvalKeysRespectIMERepeatsWindowAndBookActivity() async throws {
        let window = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let other = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let sessionActivity = RetainedPageActivity()
        let featureActivity = RetainedPageActivity()
        sessionActivity.setActive(true)
        featureActivity.setActive(true)
        let request = try CodexAgentMapping.request(method: "item/commandExecution/requestApproval", params: ["command": "ls"], rpcID: 1)
        var decisions: [Bool] = []
        let host = NSHostingView(rootView: AgentBookApprovalEntryView(request: request, pageSize: CGSize(width: 700, height: 500),
            contentBottom: 60, scale: 1, sessionActivity: sessionActivity, featureActivity: featureActivity) { _, allow in decisions.append(allow) })
        let content = try #require(window.contentView)
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        NSApplication.shared.sendEvent(try testKey(window, code: 36))
        #expect(decisions == [true])
        NSApplication.shared.sendEvent(try testKey(window, code: 36, isRepeat: true))
        NSApplication.shared.sendEvent(try testKey(window, code: 36, modifiers: .command))
        NSApplication.shared.sendEvent(try testKey(other, code: 36))
        #expect(decisions == [true])
        let composing = AgentBookComposingText(frame: .zero)
        content.addSubview(composing)
        window.makeFirstResponder(composing)
        NSApplication.shared.sendEvent(try testKey(window, code: 36))
        #expect(decisions == [true])
        window.makeFirstResponder(nil)
        sessionActivity.isActive.value = false
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true])
        sessionActivity.isActive.value = true
        featureActivity.isActive.value = false
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true])
        featureActivity.isActive.value = true
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true, false])
    }

    @Test func readingKeysMovePagesAndReturnToDraftWithoutConsumingEditorKeys() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, session: backend)
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        for index in 0..<3 {
            await store.send([.text("question \(index)")])
            backend.emit(.output(.message(AgentMessage(id: "a", role: .answer, title: "Answer",
                content: .markdown(String(repeating: "Answer \(index).\n\n", count: 100)), status: .completed))))
            backend.emit(.completed)
            #expect(await testEventually { !store.isBusy })
        }
        let focus = AgentBookFocus()
        var spread = 0
        var pageCount = 0
        let window = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AgentBookExchangeView(store: store, agentName: "Codex",
            spread: Binding(get: { spread }, set: { spread = $0 }), pageCountChanged: { pageCount = $0 }, focus: focus))
        let content = try #require(window.contentView)
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        #expect(await testEventually { focus.readingView != nil && pageCount > 2 })
        let input = NSTextView(frame: .zero)
        input.string = "draft"
        input.setSelectedRange(NSRange(location: 2, length: 0))
        content.addSubview(input)
        focus.inputView = input
        focus.activateReading()
        #expect(focus.isReading(in: window))
        let initial = spread
        try #require(initial > 0)
        NSApplication.shared.sendEvent(try testKey(window, code: 4, characters: "h"))
        #expect(await testEventually { spread == initial - 1 })
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l"))
        #expect(await testEventually { spread == initial })
        NSApplication.shared.sendEvent(try testKey(window, code: 4, characters: "h"))
        #expect(await testEventually { spread == initial - 1 })
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l", modifiers: .command))
        #expect(spread == initial - 1)
        let surface = try #require(focus.readingView as? AgentBookTextSurface)
        let visiblePages = surface.subviews.compactMap { $0 as? NSScrollView }
            .filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
        try #require(visiblePages.count == 2)
        let leftY = visiblePages[0].contentView.bounds.minY
        let rightY = visiblePages[1].contentView.bounds.minY
        NSApplication.shared.sendEvent(try testKey(window, code: 38, characters: "j"))
        #expect(visiblePages[1].contentView.bounds.minY > rightY)
        #expect(visiblePages[0].contentView.bounds.minY > leftY)
        #expect(abs((visiblePages[0].contentView.bounds.minY - leftY) - (visiblePages[1].contentView.bounds.minY - rightY)) < 1)
        NSApplication.shared.sendEvent(try testKey(window, code: 40, characters: "k"))
        #expect(abs(visiblePages[1].contentView.bounds.minY - rightY) < 1)
        #expect(abs(visiblePages[0].contentView.bounds.minY - leftY) < 1)
        NSApplication.shared.sendEvent(try testKey(window, code: 49, characters: " "))
        #expect(window.firstResponder === input)
        NSApplication.shared.sendEvent(try testKey(window, code: 40, characters: "k", isRepeat: true))
        #expect(input.string == "draft")
        #expect(input.string == "draft" && input.selectedRange() == NSRange(location: 2, length: 0))
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l"))
        #expect(spread == initial - 1)
    }
}

@MainActor
private func testKey(_ window: NSWindow, code: UInt16, characters: String = "\r",
                     modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code))
}

private final class AgentBookTestKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private final class AgentBookComposingText: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

private struct RetainedInputProbe: NSViewRepresentable {
    let created: (NSTextView) -> Void
    func makeNSView(context: Context) -> NSTextView {
        let input = NSTextView()
        created(input)
        return input
    }
    func updateNSView(_ view: NSTextView, context: Context) {}
}
