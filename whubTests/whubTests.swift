//
//  whubTests.swift
//  whubTests
//
//  Created by 村上匠 on 2026/10/08.
//

import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexReceivingTests {
    @Test func fragmentedJSONKeepsUnicodeEmptyLinesAndMultipleMessages() throws {
        let messages: [[String: Any]] = [
            ["id": 1, "text": String(repeating: "日本語👩‍💻", count: 2000)],
            ["id": 2, "text": "second"],
            ["id": 3, "text": "last"]
        ]
        var bytes = Data([10])
        for message in messages {
            bytes.append(try JSONSerialization.data(withJSONObject: message))
            bytes.append(contentsOf: [10, 10])
        }
        for chunkSize in [1, 127, bytes.count] {
            var buffer = CodexClient.LineBuffer()
            var received: [[String: Any]] = []
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                try buffer.append(Data(bytes[start..<min(start + chunkSize, bytes.count)])) {
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
        var buffer = CodexClient.LineBuffer()
        var received: [Data] = []
        buffer.append(Data("{\"id\":1}".utf8)) { received.append($0) }
        #expect(received.isEmpty)
        buffer.append(Data("\n".utf8)) { received.append($0) }
        #expect(received == [Data("{\"id\":1}".utf8)])
        #expect(throws: (any Error).self) {
            try buffer.append(Data("invalid\n".utf8)) { _ = try JSONSerialization.jsonObject(with: $0) }
        }
    }
}

@Suite @MainActor
struct CodexSteeringTests {
    private func makeStore(steer: @escaping ([String: Any]) async throws -> [String: Any]) throws -> (ModelContainer, CodexStore) {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext) { method, params, _ in
            switch method {
            case "thread/start": return ["thread": ["id": "thread-1"]]
            case "turn/start": return ["turn": ["id": "turn-1"]]
            case "turn/steer": return try await steer(params)
            case "turn/interrupt": return [:]
            default: throw CodexError(message: "Unexpected request: \(method)")
            }
        }
        return (container, store)
    }

    private func image() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        return image
    }

    private func complete(_ store: CodexStore) {
        store.receive("turn/completed", params: ["threadId": "thread-1",
            "turn": ["id": "turn-1", "status": "completed"]], requestID: nil)
    }

    @Test func additionalTextImagesAndSkillsStayInTheActiveTurn() async throws {
        var sent: [String: Any] = [:]
        let (container, store) = try makeStore { params in
            sent = params
            return ["turnId": "turn-1"]
        }
        defer { withExtendedLifetime(container) {} }
        store.draft = "first"
        await store.send()
        let original = try #require(store.turns.first)
        store.draft = "追加 $review"
        store.addImages([try image()])
        let attachment = try #require(store.draftImages.first)
        let skill = CodexSkill(name: "review", description: "review", path: "/skills/review")
        #expect(store.canSend)
        await store.send(skills: [skill])

        #expect(sent["threadId"] as? String == "thread-1")
        #expect(sent["expectedTurnId"] as? String == "turn-1")
        let input = try #require(sent["input"] as? [[String: String]])
        #expect(input == [["type": "text", "text": "追加 $review"], attachment.input,
                          ["type": "skill", "name": "review", "path": "/skills/review"]])
        #expect(store.turns.count == 1)
        #expect(store.turns[0].id == original.id)
        #expect(store.turns[0].input == [.text("first"), .text("追加 $review"), .attachment(type: "skill", name: "review")])
        #expect(store.turns[0].images.map(\.id) == [attachment.id])
        #expect(store.isBusy)
        #expect(!store.isSteering)
        #expect(store.draft.isEmpty && store.draftImages.isEmpty)
        let book = CodexBookDocument()
        book.update(store.turns)
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .dark)
        #expect(book.storage.string.contains("first\n追加 $review\nreview"))

        store.receive("item/completed", params: ["threadId": "thread-1", "turnId": "turn-1",
            "item": ["id": "user-2", "type": "userMessage", "content": [["type": "text", "text": "追加 $review"]]]], requestID: nil)
        #expect(store.turns[0].input.count == 3)
        complete(store)
        #expect(!store.isBusy)
    }

    @Test(arguments: ["rejected", "ended", "wrongTurn"])
    func failedSteeringRetainsInputWithoutFailingTheTurn(_ scenario: String) async throws {
        var store: CodexStore!
        let (container, session) = try makeStore { _ in
            if scenario == "ended" { self.complete(store) }
            if scenario == "wrongTurn" { return ["turnId": "other-turn"] }
            throw CodexError(message: "no active turn")
        }
        defer { withExtendedLifetime(container) {} }
        store = session
        store.draft = "first"
        await store.send()
        store.draft = "追加 $review"
        store.addImages([try image()])
        let imageIDs = store.draftImages.map(\.id)
        let skill = CodexSkill(name: "review", description: "review", path: "/skills/review")
        store.selectedSkills = [skill]
        await store.send(skills: [skill])
        #expect(store.draft == "追加 $review")
        #expect(store.draftImages.map(\.id) == imageIDs)
        #expect(store.selectedSkills.map(\.path) == [skill.path])
        #expect(store.turns[0].input == [.text("first")])
        #expect(store.turns[0].status == (scenario == "ended" ? "completed" : "inProgress"))
        #expect(store.isBusy == (scenario != "ended"))
        #expect(!store.isSteering)
        #expect(store.errorMessage != nil)
    }

    @Test func inFlightSteeringBlocksDuplicatesAndPreservesNewEditsAfterCompletion() async throws {
        var reply: CheckedContinuation<[String: Any], Never>?
        var calls = 0
        let (container, store) = try makeStore { _ in
            calls += 1
            return await withCheckedContinuation { reply = $0 }
        }
        defer { withExtendedLifetime(container) {} }
        store.draft = "first"
        await store.send()
        store.draft = "追加"
        store.addImages([try image()])
        let sentImage = try #require(store.draftImages.first)
        let sending = Task { await store.send() }
        while reply == nil { await Task.yield() }
        #expect(store.isSteering)
        #expect(!store.canSend)
        await store.send()
        #expect(calls == 1)
        store.draft = "次の下書き"
        store.addImages([try image()])
        let nextImage = try #require(store.draftImages.last)
        complete(store)
        #expect(!store.isBusy)
        #expect(!store.canSend)
        await store.send()
        #expect(store.turns.count == 1)
        reply?.resume(returning: ["turnId": "turn-1"])
        await sending.value
        #expect(store.turns[0].status == "completed")
        #expect(store.turns[0].input == [.text("first"), .text("追加")])
        #expect(store.turns[0].images.map(\.id) == [sentImage.id])
        #expect(store.draft == "次の下書き")
        #expect(store.draftImages.map(\.id) == [nextImage.id])
        #expect(store.canSend)
        await store.send()
        #expect(store.turns.count == 2)
        #expect(store.turns[1].input == [.text("次の下書き")])
        #expect(store.turns[1].images.map(\.id) == [nextImage.id])
        #expect(calls == 1)
    }

    @Test func startingAndStoppingTurnsDoNotAcceptSteering() async throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var startReply: CheckedContinuation<[String: Any], Never>?
        var methods: [String] = []
        let store = CodexStore(context: container.mainContext) { method, _, _ in
            methods.append(method)
            if method == "thread/start" { return ["thread": ["id": "thread-1"]] }
            if method == "turn/start" { return await withCheckedContinuation { startReply = $0 } }
            return [:]
        }
        store.draft = "first"
        let starting = Task { await store.send() }
        while startReply == nil { await Task.yield() }
        store.draft = "追加"
        #expect(!store.canSend)
        await store.send()
        startReply?.resume(returning: ["turn": ["id": "turn-1"]])
        await starting.value
        #expect(store.canSend)
        await store.interrupt()
        #expect(store.isStopping)
        #expect(!store.canSend)
        await store.send()
        #expect(methods == ["thread/start", "turn/start", "turn/interrupt"])
        #expect(store.draft == "追加")
    }

    @Test func resumedHistoryIncludesEveryAdditionalUserMessage() throws {
        let result: [String: Any] = ["cwd": "/project", "model": "model", "thread": [
            "id": "thread-1", "turns": [["id": "turn-1", "status": "completed", "items": [
                ["id": "u1", "type": "userMessage", "content": [["type": "text", "text": "first"]]],
                ["id": "u2", "type": "userMessage", "content": [["type": "text", "text": "追加"], ["type": "skill", "name": "review"]]],
                ["id": "u3", "type": "userMessage", "content": [["type": "image"]]]
            ]]]]]
        let history = try CodexThreadHistory(result, expectedID: "thread-1")
        #expect(history.turns.count == 1)
        #expect(history.turns[0].input == [.text("first"), .text("追加"), .attachment(type: "skill", name: "review"),
                                          .attachment(type: "image", name: nil)])
        #expect(history.turns[0].displayPrompt == "first\n追加\nreview\n［添付: image］")
    }
}

@Suite @MainActor
struct CodexResumeTests {
    @Test func resumeInputRequiresTheWholeCommand() {
        #expect(CodexInputView.isResumeInput("/resume"))
        #expect(CodexInputView.isResumeInput(" /resume \n"))
        #expect(!CodexInputView.isResumeInput("/res"))
        #expect(!CodexInputView.isResumeInput("説明 /resume"))
        #expect(!CodexInputView.isResumeInput("/resume 続き"))
        #expect(CodexCommand.allCases.contains(.resume))
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func response(_ turns: [[String: Any]]) -> [String: Any] {
        ["thread": ["id": "thread-1", "turns": turns], "cwd": "/original/project", "model": "saved-model"]
    }

    @Test func recentThreadUsesTitleThenPreviewAndRejectsMissingDirectory() throws {
        var data: [String: Any] = ["id": "thread-1", "cwd": "/project", "updatedAt": 123.0,
                                   "name": "  タイトル  ", "preview": "冒頭文"]
        #expect(try CodexRecentThread(data).displayTitle == "タイトル")
        data["name"] = NSNull()
        #expect(try CodexRecentThread(data).displayTitle == "冒頭文")
        #expect(try CodexRecentThread(data).updatedAt == Date(timeIntervalSince1970: 123))
        data["preview"] = "  "
        #expect(try CodexRecentThread(data).displayTitle == "thread-1")
        data.removeValue(forKey: "cwd")
        #expect(throws: CodexError.self) { try CodexRecentThread(data) }
    }

    @Test func restoresHistoryDirectoryAndLegacyFinalAnswer() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let originalDirectory = store.directory
        let items: [[String: Any]] = [
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "質問"]]],
            ["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "確認中"],
            ["id": "cmd", "type": "commandExecution", "command": "pwd", "aggregatedOutput": "/project", "status": "completed"],
            ["id": "answer", "type": "agentMessage", "text": "回答"]
        ]
        try store.restoreHistory(response([["id": "turn-1", "status": "completed", "items": items]]), expectedID: "thread-1")
        #expect(store.threadID == "thread-1")
        #expect(store.directory == "/original/project")
        #expect(store.model == "saved-model")
        let turn = try #require(store.turns.first)
        #expect(turn.remoteID == "turn-1")
        #expect(turn.displayPrompt == "質問")
        #expect(turn.answers.map(\.displayText) == ["回答"])
        #expect(turn.history.map(\.id) == ["progress", "cmd"])
        #expect(!store.isBusy)
        store.reset()
        #expect(store.threadID == nil)
        #expect(store.directory == originalDirectory)
    }

    @Test func incompleteHistoryDoesNotPartiallyReplaceState() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let directory = store.directory
        let complete: [String: Any] = ["id": "a", "status": "completed", "items": [[String: Any]]()]
        let invalidTurns: [[String: Any]] = [
            ["id": "b", "status": "inProgress", "items": [[String: Any]]()],
            ["id": "b", "status": "completed", "itemsView": "summary", "items": [[String: Any]]()],
            ["id": "b", "status": "completed"]
        ]
        for invalid in invalidTurns {
            #expect(throws: CodexError.self) {
                try store.restoreHistory(response([complete, invalid]), expectedID: "thread-1")
            }
            #expect(store.turns.isEmpty)
            #expect(store.threadID == nil)
            #expect(store.directory == directory)
        }
        #expect(throws: CodexError.self) { try store.restoreHistory(response([]), expectedID: "wrong-id") }
    }

    @Test func attachmentsRemainVisibleAndCommentaryIsNotAnAnswer() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let items: [[String: Any]] = [
            ["id": "u", "type": "userMessage", "content": [["type": "image", "url": "https://example.invalid/image"]]],
            ["id": "p", "type": "agentMessage", "phase": "commentary", "text": "途中"]
        ]
        try store.restoreHistory(response([["id": "turn-1", "status": "interrupted", "items": items]]), expectedID: "thread-1")
        #expect(store.turns.first?.input == [.attachment(type: "image", name: nil)])
        #expect(store.turns.first?.displayPrompt == "［添付: image］")
        let book = CodexBookDocument()
        book.update(store.turns)
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .dark)
        #expect(book.storage.string.contains("［添付: image］"))
        let mixedInput: [[String: Any]] = [
            ["type": "text", "text": "質問"],
            ["type": "skill", "name": "review"],
            ["type": "image", "name": "ignored"],
            [:]
        ]
        let mixed = try CodexThreadHistory(response([["id": "mixed", "status": "completed", "items": [
            ["id": "u", "type": "userMessage", "content": mixedInput]
        ]]]), expectedID: "thread-1")
        #expect(mixed.turns.first?.input == [.text("質問"), .attachment(type: "skill", name: "review"),
            .attachment(type: "image", name: "ignored"),
            .attachment(type: nil, name: nil)])
        #expect(mixed.turns.first?.displayPrompt == "質問\nreview\n［添付: image］\n［添付: 不明］")
        #expect(store.turns.first?.answers.isEmpty == true)
        #expect(store.turns.first?.status == "interrupted")
        #expect(throws: CodexError.self) { try store.restoreHistory(response([]), expectedID: "thread-1") }
        #expect(store.turns.count == 1)
    }

    @Test func resumedBookReplacesSourceInPlaceAndParticipatesInNotifications() throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        let before = tabs.selectedSession
        tabs.add()
        let original = tabs.selectedSession
        original.draft = "編集中の入力"
        original.onCompletionChange?(true)
        tabs.add()
        let after = tabs.selectedSession
        let resumed = CodexStore(context: container.mainContext)
        try resumed.restoreHistory(response([]), expectedID: "thread-1")
        #expect(tabs.openResumedSession(resumed, replacing: original.id))
        #expect(tabs.sessions.map(\.id) == [before.id, resumed.id, after.id])
        #expect(tabs.selectedSessionID == resumed.id)
        #expect(tabs.completedSessionIDs.isEmpty)
        original.onCompletionChange?(true)
        #expect(tabs.completedSessionIDs.isEmpty)
        resumed.onCompletionChange?(true)
        #expect(tabs.completedSessionIDs == [resumed.id])
        tabs.remove(resumed.id)
        #expect(tabs.selectedSessionID == after.id)
        #expect(tabs.completedSessionIDs.isEmpty)
    }

    @Test(arguments: [true, false])
    func alreadyOpenBookMovesToSourceWithoutDuplicateTabs(_ targetBeforeSource: Bool) async throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        tabs.add()
        tabs.add()
        let original = tabs.sessions[targetBeforeSource ? 0 : 2]
        let source = tabs.sessions[1]
        let other = tabs.sessions[targetBeforeSource ? 2 : 0]
        try original.restoreHistory(response([]), expectedID: "thread-1")
        original.draft = "既存Bookの下書き"
        original.onCompletionChange?(true)
        source.onCompletionChange?(true)
        let thread = try CodexRecentThread(["id": "thread-1", "cwd": "/not-needed", "updatedAt": 1.0])
        #expect(await tabs.resume(thread, replacing: source.id))
        #expect(tabs.sessions.map(\.id) == (targetBeforeSource ? [original.id, other.id] : [other.id, original.id]))
        #expect(tabs.selectedSessionID == original.id)
        #expect(tabs.completedSessionIDs.isEmpty)
        #expect(original.draft == "既存Bookの下書き")
        let duplicate = CodexStore(context: container.mainContext)
        try duplicate.restoreHistory(response([]), expectedID: "thread-1")
        #expect(tabs.openResumedSession(duplicate, replacing: original.id))
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selectedSessionID == original.id)
    }

    @Test func failedResumeLeavesTabsAndInputUntouched() async throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        let original = tabs.selectedSession
        original.draft = "入力を保持"
        let thread = try CodexRecentThread(["id": "missing", "cwd": "/nonexistent-" + UUID().uuidString, "updatedAt": 1.0])
        #expect(await tabs.resume(thread, replacing: original.id) == false)
        #expect(tabs.sessions.map(\.id) == [original.id])
        #expect(tabs.selectedSessionID == original.id)
        #expect(original.draft == "入力を保持")
        #expect(tabs.resumeError?.contains("作業フォルダが存在しません") == true)
        #expect(!tabs.isResuming)
        #expect(!tabs.openResumedSession(CodexStore(context: container.mainContext), replacing: original.id))
        #expect(tabs.sessions.count == 1)
    }

    @Test(arguments: ["select", "close", "start"])
    func pendingResumeKeepsItsSourceAndDoesNotReplaceClosedOrBusyTabs(_ action: String) async throws {
        let container = try makeContainer()
        var reply: CheckedContinuation<[String: Any], Never>?
        var methods: [String] = []
        let tabs = CodexTabsStore(context: container.mainContext) { method, _, _ in
            methods.append(method)
            switch method {
            case "thread/read": return ["thread": ["id": "thread-1"]]
            case "thread/resume": return await withCheckedContinuation { reply = $0 }
            case "thread/start": return ["thread": ["id": "source-thread"]]
            case "turn/start": return ["turn": ["id": "source-turn"]]
            default: throw CodexError(message: "Unexpected request: \(method)")
            }
        }
        let source = tabs.selectedSession
        source.draft = "/resume"
        tabs.add()
        let other = tabs.selectedSession
        other.draft = "他タブの下書き"
        let thread = try CodexRecentThread(["id": "thread-1", "cwd": NSHomeDirectory(), "updatedAt": 1.0])
        let loading = Task { await tabs.resume(thread, replacing: source.id) }
        while reply == nil { await Task.yield() }
        #expect(tabs.isResuming)
        #expect(!tabs.openResumedSession(CodexStore(context: container.mainContext), replacing: source.id))
        if action == "close" {
            tabs.remove(source.id)
            #expect(!tabs.isResuming)
        } else if action == "start" {
            source.draft = "開始する依頼"
            await source.send()
        } else {
            tabs.select(other.id)
        }
        reply?.resume(returning: response([]))
        let succeeded = await loading.value
        #expect(!tabs.isResuming)
        #expect(other.draft == "他タブの下書き")
        if action == "select" {
            #expect(succeeded)
            #expect(tabs.sessions.count == 2)
            #expect(tabs.sessions[0].threadID == "thread-1")
            #expect(tabs.sessions[1] === other)
            #expect(!tabs.sessions.contains { $0.id == source.id })
            #expect(tabs.selectedSessionID == tabs.sessions[0].id)
        } else if action == "close" {
            #expect(!succeeded)
            #expect(tabs.sessions.map(\.id) == [other.id])
            #expect(tabs.selectedSessionID == other.id)
        } else {
            #expect(!succeeded)
            #expect(tabs.sessions.map(\.id) == [source.id, other.id])
            #expect(source.isBusy)
            #expect(source.threadID == "source-thread")
            #expect(!methods.contains("turn/interrupt"))
            #expect(tabs.resumeError != nil)
        }
    }

    @Test func busySourceRejectsResumeBeforeReadingHistory() async throws {
        let container = try makeContainer()
        var methods: [String] = []
        let tabs = CodexTabsStore(context: container.mainContext) { method, _, _ in
            methods.append(method)
            if method == "thread/start" { return ["thread": ["id": "source-thread"]] }
            return ["turn": ["id": "source-turn"]]
        }
        let source = tabs.selectedSession
        source.draft = "処理中の依頼"
        await source.send()
        source.draft = "/resume"
        let thread = try CodexRecentThread(["id": "thread-1", "cwd": NSHomeDirectory(), "updatedAt": 1.0])
        #expect(await tabs.resume(thread, replacing: source.id) == false)
        #expect(methods == ["thread/start", "turn/start"])
        #expect(source.isBusy)
        #expect(source.draft == "/resume")
        #expect(tabs.sessions.map(\.id) == [source.id])
        #expect(tabs.resumeError != nil)
    }
}

@Suite @MainActor
struct CodexCompletionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func completionsBelongToSecondAndFourthTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<3 { store.add() }
        let ids = store.sessions.map(\.id)
        var published: Set<CodexStore.ID> = []
        let observation = store.$completedSessionIDs.sink { published = $0 }
        defer { observation.cancel() }

        store.sessions[1].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1]])
        store.sessions[3].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1], ids[3]])
        #expect(published == [ids[1], ids[3]])

        store.select(ids[1])
        #expect(store.completedSessionIDs == [ids[3]])
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
        store.sessions[3].onCompletionChange?(true)
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func completionSurvivesReorderingAndHiddenTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<5 { store.add() }
        let first = store.sessions[0]
        let sixth = store.sessions[5]
        store.select(first.id)
        sixth.onCompletionChange?(true)
        let visible = CodexTabBar.visibleRange(count: store.sessions.count, selectedIndex: 0)
        #expect(visible == 0..<5)
        #expect(store.completedSessionIDs == [sixth.id])

        store.move(sixth.id, before: first.id)
        #expect(store.sessions[0].id == sixth.id)
        #expect(store.completedSessionIDs == [sixth.id])
        store.select(sixth.id)
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func resetAndRestartClearOnlyTheirOwnCompletion() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let first = store.sessions[0]
        let second = store.sessions[1]
        first.onCompletionChange?(true)
        second.onCompletionChange?(true)
        first.onCompletionChange?(false)
        #expect(store.completedSessionIDs == [second.id])
        second.reset()
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func removedTabsCannotRestoreTheirBadge() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let removed = store.sessions[1]
        removed.onCompletionChange?(true)
        store.remove(removed.id)
        #expect(store.completedSessionIDs.isEmpty)
        removed.onCompletionChange?(true)
        #expect(store.completedSessionIDs.isEmpty)
    }
}

@Suite @MainActor
struct CodexImageTests {
    private func image() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        return image
    }

    @Test func pasteAcceptsPNGAndTIFFAndKeepsTextPasting() throws {
        let image = try image()
        let attachment = try #require(CodexImageAttachment(image: image))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = CodexTextView(frame: .zero)
        view.isRichText = false
        var pasted: [NSImage] = []
        view.pasteImages = { pasted += $0 }

        pasteboard.setData(attachment.pngData, forType: .png)
        #expect(view.readablePasteboardTypes.first == .png)
        #expect(view.readSelection(from: pasteboard, type: .png))
        #expect(pasted.count == 1)
        pasteboard.clearContents()
        pasteboard.setData(try #require(image.tiffRepresentation), forType: .tiff)
        #expect(view.readSelection(from: pasteboard, type: .tiff))
        #expect(pasted.count == 2)

        pasteboard.clearContents()
        pasteboard.setString("貼り付けテキスト", forType: .string)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string == "貼り付けテキスト")
        #expect(pasted.count == 2)
    }

    @Test func attachmentsAreIsolatedRemovableAndSentAsPNG() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tabs = CodexTabsStore(context: container.mainContext)
        tabs.add()
        let first = tabs.sessions[0], second = tabs.sessions[1]
        first.addImages([try image()])
        #expect(first.canSend)
        #expect(!second.canSend)
        #expect(second.draftImages.isEmpty)
        let attachment = try #require(first.draftImages.first)
        #expect(attachment.input["type"] == "image")
        let url = try #require(attachment.input["url"])
        #expect(url.hasPrefix("data:image/png;base64,"))
        let data = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        #expect(data == attachment.pngData)
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 2)

        first.draftImages.removeAll { $0.id == attachment.id }
        #expect(!first.canSend)
        first.addImages([try image()])
        first.reset()
        #expect(first.draftImages.isEmpty)
    }

    @Test func notebookKeepsPromptAndImagesInOrder() throws {
        let images = try (0..<2).map { _ in try #require(CodexImageAttachment(image: image())) }
        let book = CodexBookDocument()
        let turn = CodexTurn(prompt: "何が写ってる？", images: images)
        book.update([turn])
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .dark)
        #expect(book.storage.string.hasPrefix(turn.displayPrompt))
        var rendered: [NSImage] = []
        book.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: book.storage.length)) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image { rendered.append(image) }
        }
        #expect(rendered.count == images.count)
        for (actual, expected) in zip(rendered, images) { #expect(actual === expected.image) }
        #expect(NSMaxRange(try #require(book.ranges.last)) == book.storage.length)
    }

    @Test func notebookKeepsImagesAcrossPagesAndResponseUpdates() throws {
        let images = try (0..<3).map { _ in try #require(CodexImageAttachment(image: image())) }
        for prompt in ["", String(repeating: "画像を確認してください。", count: 100)] {
            let book = CodexBookDocument()
            var turn = CodexTurn(prompt: prompt, images: images)
            for completed in [false, true] {
                if completed {
                    turn.items = [CodexItem(id: "answer", type: "agentMessage", phase: "final_answer",
                                           text: "確認しました", status: "completed")]
                    turn.status = "completed"
                }
                book.update(completed ? [turn, CodexTurn(prompt: "次の質問")] : [turn])
                book.prepare(viewport: CGSize(width: 600, height: 320), colorScheme: .dark)
                var rendered: [NSImage] = []
                book.storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: book.storage.length)) { value, _, _ in
                    if let image = (value as? NSTextAttachment)?.image { rendered.append(image) }
                }
                #expect(rendered.count == images.count)
                for (actual, expected) in zip(rendered, images) { #expect(actual === expected.image) }
                #expect(book.ranges.count > 1)
                #expect(NSMaxRange(try #require(book.ranges.last)) == book.storage.length)
            }
        }
    }

    @Test func invalidImageDoesNotBecomeAnAttachment() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        store.addImages([NSImage()])
        #expect(store.draftImages.isEmpty)
        #expect(store.errorMessage != nil)
    }
}

@Suite @MainActor
struct CodexApprovalTests {
    @Test func streamedItemsAndApprovalPreviewsKeepTheirProtocolData() async throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext) { method, _, _ in
            if method == "thread/start" { return ["thread": ["id": "thread-1"]] }
            return ["turn": ["id": "turn-1"]]
        }
        store.draft = "test"
        await store.send()
        func item(_ data: [String: Any], completed: Bool = false) {
            store.receive(completed ? "item/completed" : "item/started",
                          params: ["threadId": "thread-1", "item": data], requestID: nil)
        }
        item(["id": "answer", "type": "agentMessage"])
        for delta in ["答", "え"] {
            store.receive("item/agentMessage/delta", params: ["threadId": "thread-1", "itemId": "answer", "delta": delta], requestID: nil)
        }
        item(["id": "answer", "type": "agentMessage", "phase": "final_answer"], completed: true)
        #expect(store.turns.last?.answers.first?.displayText == "答え")

        item(["id": "command", "type": "commandExecution", "command": "pwd"])
        store.receive("item/commandExecution/outputDelta", params: ["threadId": "thread-1", "itemId": "command", "delta": "/old"], requestID: nil)
        item(["id": "command", "type": "commandExecution", "command": "pwd", "aggregatedOutput": "/project"], completed: true)
        let command = try #require(store.turns.last?.items.first { $0.id == "command" })
        #expect(command.displayTitle == "pwd")
        #expect(command.displayText == "/project")

        let changes = [["path": "file.swift", "diff": "+new"]]
        item(["id": "file", "type": "fileChange", "changes": changes])
        let file = try #require(store.turns.last?.items.first { $0.id == "file" })
        #expect(file.text == nil)
        #expect(file.displayTitle == "ファイル変更")
        #expect(file.displayText == "file.swift\n+new")
        store.receive("item/fileChange/requestApproval", params: ["itemId": "file"], requestID: 1)
        #expect(store.requests.first?.params["changes"] as? [[String: String]] == changes)
        #expect(store.requests.first?.params["changePreview"] == nil)
        store.resolveRequest("1", outcome: .accepted)
        store.receive("item/commandExecution/requestApproval", params: [:], requestID: 2)
        store.receive("turn/completed", params: ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]], requestID: nil)
        let outcomes = try #require(store.turns.last).approvals.compactMap(\.outcome)
        #expect(outcomes == [.accepted, .unanswered])
        #expect(outcomes.map(\.displayText) == ["承認済み", "終了（未回答）"])
    }

    @Test func approvalArrivalAndResolutionKeepPagesAndReadingPosition() async throws {
        let book = CodexBookDocument()
        var turn = CodexTurn(prompt: String(repeating: "本文を読み続ける。\n\n", count: 100))
        book.update([turn])
        book.togglePrompt(turn.id)
        book.prepare(viewport: CGSize(width: 800, height: 650), colorScheme: .dark)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(NSMaxRange(try #require(book.ranges.last)) == book.storage.length)
        #expect(book.storage.string.contains(turn.displayPrompt))
        #expect(book.spreadCount > 1)
        book.move(1)
        book.move(-1)
        let pages = book.ranges
        let revision = book.revision
        let spread = book.spread
        for (index, method) in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                                "item/permissions/requestApproval"].enumerated() {
            turn.approvals.append(CodexRequest(rpcID: index, method: method,
                params: ["command": String(repeating: "echo long-command\n", count: 100)]))
            book.update([turn])
            #expect(book.ranges == pages)
            #expect(book.revision == revision)
            #expect(book.spread == spread)
        }
        for index in turn.approvals.indices {
            turn.approvals[index].outcome = index.isMultiple(of: 2) ? .accepted : .declined
            book.update([turn])
            #expect(book.ranges == pages)
            #expect(book.spread == spread)
        }
        turn.status = "completed"
        book.update([turn])
        #expect(book.ranges == pages)
        #expect(book.spread == spread)
        #expect(turn.approvals.count == 3)
    }

    @Test func approvalHeightFitsShortContentAndCapsLongDetails() {
        let short = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
            params: ["command": "pwd", "cwd": "/Users/test", "reason": "確認"])
        let long = CodexRequest(rpcID: 2, method: short.method,
            params: ["command": String(repeating: "echo long-command\n", count: 100),
                     "cwd": "/Users/test", "reason": "確認"])
        for request in [short, long] {
            for expanded in [false, true] {
                let view = NSHostingView(rootView:
                    CodexInteractionRequestView(request: request, detailsExpanded: expanded) { _ in }
                        .frame(width: 320)
                        .frame(maxHeight: 440))
                view.frame.size = view.fittingSize
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.width <= 320)
                #expect(view.fittingSize.height <= 440)
                if request.id == short.id, !expanded {
                    #expect(view.fittingSize.height < 250)
                }
            }
        }
    }

    @Test func keysIgnoreCompositionRepeatsAndUnrelatedKeys() {
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 76, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 53, isRepeat: false, hasMarkedText: false) == false)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: true, hasMarkedText: false) == nil)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: true) == nil)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 123, isRepeat: false, hasMarkedText: false) == nil)
    }

    @Test(arguments: [true, false])
    func approvalButtonsOnlyUseNativeKeyEquivalentsWhenEnabled(_ usesNativeKeyEquivalents: Bool) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        var decisions: [Bool] = []
        let request = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
                                   params: ["command": "pwd"])
        let view = NSHostingView(rootView:
            CodexInteractionRequestView(request: request, approvalDecision: { decisions.append($0) },
                                       usesNativeKeyEquivalents: usesNativeKeyEquivalents) { _ in }
                .frame(width: 320, height: 240))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            #expect(window.performKeyEquivalent(with: event) == usesNativeKeyEquivalents)
        }
        #expect(decisions == (usesNativeKeyEquivalents ? [true, false] : []))
    }

    @Test func approvalKeyViewDoesNotActivateItsWindow() throws {
        final class Window: NSWindow {
            var requestedKey = false
            override func makeKey() { requestedKey = true }
        }
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let view = CodexApprovalKeys.EventView(frame: content.bounds)
        content.addSubview(view)
        #expect(!window.requestedKey)
        window.requestedKey = false
        view.removeFromSuperview()
        #expect(!window.requestedKey)
    }

    @Test func inactiveBooksDoNotConsumeApprovalKeysOrResolveRequests() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        store.receive("item/commandExecution/requestApproval", params: ["command": "pwd"], requestID: 1)
        let session = RetainedPageActivity()
        let feature = RetainedPageActivity()
        var decisions: [Bool] = []
        let keys = CodexApprovalKeys(isActive: { session.isActive.value && feature.isActive.value }) {
            decisions.append($0)
        }
        func event(_ code: UInt16) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        for (sessionActive, featureActive) in [(true, false), (false, true), (false, false)] {
            session.setActive(sessionActive)
            feature.setActive(featureActive)
            #expect(!keys.handle(try event(36), in: window))
            #expect(!keys.handle(try event(53), in: window))
        }
        #expect(decisions.isEmpty)
        #expect(store.requests.map(\.id) == ["1"])
        #expect(store.requests[0].outcome == nil)
        session.setActive(true)
        feature.setActive(true)
        #expect(keys.handle(try event(36), in: window))
        #expect(keys.handle(try event(53), in: window))
        #expect(decisions == [true, false])
    }

    @Test func approvalCardBelongsToItsRetainedBookAcrossTabAndFeatureSwitches() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try #require(window.contentView)
        let coordinator = RetainedPageContainer<Int, CodexApprovalEntryView>.Coordinator()
        let feature = RetainedPageActivity()
        feature.setActive(true)
        let request = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
                                   params: ["command": "pwd"])
        var decisions: [Bool] = []
        let root: (Int, RetainedPageActivity) -> AnyView = { id, activity in
            AnyView(CodexApprovalEntryView(request: id == 1 ? request : nil,
                pageSize: CGSize(width: 400, height: 600), contentBottom: 100, scale: 1,
                sessionActivity: activity, featureActivity: feature,
                decide: { _, allow in decisions.append(allow) }))
        }
        func approvalKeyViews(in view: NSView) -> [CodexApprovalKeys.EventView] {
            (view as? CodexApprovalKeys.EventView).map { [$0] } ?? view.subviews.flatMap { approvalKeyViews(in: $0) }
        }
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        let first = try #require(coordinator.pages[1])
        first.view.layoutSubtreeIfNeeded()
        let keyView = try #require(approvalKeyViews(in: first.view).first)
        #expect(keyView.window === window)
        #expect(window.childWindows?.isEmpty != false)
        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(keyView.isHiddenOrHasHiddenAncestor)
        #expect(!first.activity.isActive.value)
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        first.view.layoutSubtreeIfNeeded()
        #expect(approvalKeyViews(in: first.view).first === keyView)
        #expect(!keyView.isHiddenOrHasHiddenAncestor)
        feature.setActive(false)
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: false, rootView: root)
        #expect(!first.activity.isActive.value)
        feature.setActive(true)
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        first.view.layoutSubtreeIfNeeded()
        #expect(approvalKeyViews(in: first.view).first === keyView)
        #expect(first.activity.isActive.value)
        #expect(decisions.isEmpty)
        #expect(request.outcome == nil)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func approvalKeysOnlyDecideInTheirOwnWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                             styleMask: [.titled], backing: .buffered, defer: false)
        var decisions: [Bool] = []
        let keys = CodexApprovalKeys { decisions.append($0) }
        func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeats: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: repeats, keyCode: code))
        }
        #expect(!keys.handle(try event(36), in: other))
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!keys.handle(try event(36, modifiers: modifiers), in: window))
            #expect(!keys.handle(try event(53, modifiers: modifiers), in: window))
        }
        for code: UInt16 in [4, 37, 44, 123, 124] {
            #expect(!keys.handle(try event(code), in: window))
        }
        #expect(decisions.isEmpty)
        #expect(keys.handle(try event(36), in: window))
        #expect(keys.handle(try event(76, modifiers: [.numericPad, .function]), in: window))
        #expect(keys.handle(try event(53), in: window))
        #expect(keys.handle(try event(36, repeats: true), in: window))
        #expect(keys.handle(try event(53, repeats: true), in: window))
        #expect(decisions == [true, true, false])
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.setMarkedText("変換中", selectedRange: NSRange(location: 0, length: 3),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        #expect(!keys.handle(try event(36), in: window))
        #expect(!keys.handle(try event(53), in: window))
        #expect(decisions == [true, true, false])
    }

    @Test func pendingRequestsResolveIndependentlyAndIgnoreDuplicateResponses() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        var sounds: [String] = []
        store.onNotification = { sounds.append($0) }
        for id in [1, 1, 2] {
            store.receive("item/commandExecution/requestApproval", params: [:], requestID: id)
        }
        #expect(store.requests.count == 2)
        #expect(sounds == ["Blow", "Blow"])
        let notificationDate = store.notificationDate
        #expect(notificationDate != nil)
        let first = try #require(store.requests.first)
        store.receive("serverRequest/resolved", params: ["requestId": 1], requestID: nil)
        #expect(store.requests.map(\.id) == ["2"])
        #expect(sounds == ["Blow", "Blow"])
        #expect(store.notificationDate == notificationDate)
        store.approve(first, allow: true)
        #expect(store.errorMessage == nil)
        #expect(store.requests.count == 1)
        store.approve(try #require(store.requests.first), allow: false)
        #expect(store.errorMessage != nil)
        #expect(store.requests.map(\.id) == ["2"])
    }
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

@MainActor
private final class CodexLayoutProbe: NSObject, NSLayoutManagerDelegate {
    var laidOutContainers: [NSTextContainer] = []

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        laidOutContainers.append(textContainer)
        return false
    }
}

@Suite @MainActor
struct CodexReadingTests {
    @Test func tailUpdateDoesNotLayOutUnchangedFrontPages() throws {
        let book = CodexBookDocument()
        let probe = CodexLayoutProbe()
        book.manager.delegate = probe
        var turns = (0..<8).map { index in
            CodexTurn(prompt: "Question \(index)", items: [
                CodexItem(id: "answer-\(index)", type: "agentMessage", phase: "final_answer",
                          text: String(repeating: "Paragraph \(index).\n\n", count: 12), status: "completed")
            ])
        }
        let viewport = CGSize(width: 800, height: 450)
        let surface = CodexBookTextSurface(book: book)
        surface.colorScheme = .light
        surface.frame.size = viewport
        book.update(turns)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        try #require(book.ranges.count > 4)
        let firstContainer = try #require(book.manager.textContainers.first)
        probe.laidOutContainers.removeAll()
        turns[7].items[0].text = "Updated final answer."
        book.update(turns)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(!probe.laidOutContainers.isEmpty)
        #expect(!probe.laidOutContainers.contains { $0 === firstContainer })
        let fresh = CodexBookDocument()
        fresh.update(turns)
        fresh.prepare(viewport: viewport, colorScheme: .light)
        #expect(book.ranges == fresh.ranges)
    }

    @Test func incrementalPaginationMatchesFreshLayoutAcrossEditsAndResize() throws {
        let book = CodexBookDocument()
        var turns = (0..<8).map { index in
            var turn = CodexTurn(prompt: "Question \(index)")
            turn.items = [CodexItem(id: "answer-\(index)", type: "agentMessage", phase: "final_answer",
                                   text: String(repeating: "Paragraph \(index). 日本語の本文。\n\n", count: 12), status: "completed")]
            return turn
        }
        var viewport = CGSize(width: 800, height: 450)
        var scheme = ColorScheme.light
        book.update(turns)
        book.prepare(viewport: viewport, colorScheme: scheme)
        let originalRanges = book.ranges
        try #require(originalRanges.count > 4)

        for edit in 0..<6 {
            switch edit {
            case 0: turns[7].items[0].text = (turns[7].items[0].text ?? "") + "\n\nAppended answer.\n\n```swift\nlet value = 1\n```"
            case 1: turns[4].items[0].text = "Shortened middle answer."
            case 2: turns.removeLast(3)
            case 3: turns.removeAll()
            case 4:
                turns = [CodexTurn(prompt: "New conversation")]
                viewport = CGSize(width: 600, height: 320)
            default: scheme = .dark
            }
            book.update(turns)
            #expect(book.prepare(viewport: viewport, colorScheme: scheme))
            let fresh = CodexBookDocument()
            fresh.update(turns)
            fresh.prepare(viewport: viewport, colorScheme: scheme)
            #expect(book.storage.string == fresh.storage.string)
            #expect(book.ranges == fresh.ranges)
            #expect(book.codes.map(\.text) == fresh.codes.map(\.text))
            #expect(book.headers.map(\.frame) == fresh.headers.map(\.frame))
            #expect(NSMaxRange(try #require(book.ranges.last)) == book.storage.length)
            #expect(book.manager.textContainers.count == book.ranges.count)
            #expect(!book.prepare(viewport: viewport, colorScheme: scheme))
            if edit == 0 { #expect(Array(book.ranges.prefix(3)) == Array(originalRanges.prefix(3))) }
        }
    }

    @Test func promptCollapseThresholdsCountCharactersAndExplicitLines() {
        #expect(CodexBookDocument.collapsedPrompt(String(repeating: "あ", count: 500)) == nil)
        #expect(CodexBookDocument.collapsedPrompt(String(repeating: "👩‍💻", count: 501)) == String(repeating: "👩‍💻", count: 500) + "…")
        #expect(CodexBookDocument.collapsedPrompt(Array(repeating: "line", count: 6).joined(separator: "\r\n")) == nil)
        #expect(CodexBookDocument.collapsedPrompt((1...7).map(String.init).joined(separator: "\n")) == "1\n2\n3\n4\n5\n6…")
        #expect(CodexBookDocument.collapsedPrompt("short") == nil)
    }

    @Test func longPromptCanExpandCollapseAndStayExpandedDuringAnswerUpdates() async throws {
        let book = CodexBookDocument()
        let prompt = (1...80).map { "error line \($0)" }.joined(separator: "\n")
        var turn = CodexTurn(prompt: prompt)
        book.update([turn])
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .light)
        #expect(book.storage.string.contains("error line 6…"))
        #expect(!book.storage.string.contains("error line 80"))
        #expect(book.promptControls.map(\.id) == [turn.id])
        #expect(book.promptControls.allSatisfy { $0.frame.height == 20 && book.ranges.indices.contains($0.page) })
        let collapsedPages = book.ranges.count
        book.togglePrompt(turn.id)
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .light)
        #expect(book.storage.string.contains(prompt))
        #expect(book.ranges.count > collapsedPages)
        turn.items = [CodexItem(id: "answer", type: "agentMessage", phase: "final_answer", text: "answer", status: "completed")]
        book.update([turn])
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .dark)
        #expect(book.isPromptExpanded(turn.id))
        #expect(book.storage.string.contains(prompt))
        #expect(book.storage.string.contains("answer"))
        book.togglePrompt(turn.id)
        book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: .dark)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!book.storage.string.contains("error line 80"))
        #expect(book.spread == (try #require(book.promptControls.first)).page / 2)
        #expect(NSMaxRange(try #require(book.ranges.last)) == book.storage.length)
        #expect(turn.displayPrompt == prompt)
        book.update([])
        #expect(!book.isPromptExpanded(turn.id))
    }

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

    @Test func textReplacementKeepsReadingFocusAndSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let book = CodexBookDocument()
        var turn = CodexTurn(prompt: "first page")
        book.update([turn])
        let surface = CodexBookTextSurface(book: book)
        surface.frame = content.bounds
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let focus = CodexBookFocus()
        focus.readingView = surface
        focus.activateReading()
        let text = try #require(window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        turn.items = [CodexItem(id: "answer", type: "agentMessage", phase: "final_answer",
                               text: "appended answer", status: "completed")]
        book.update([turn])
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(focus.isReading(in: window))
        #expect(text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(book.storage.string.contains("appended answer"))
    }

    @Test func removingPagesDoesNotStealInputFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let focus = CodexBookFocus()
        let book = CodexBookDocument()
        let turn = CodexTurn(prompt: String(repeating: "長い本文。\n\n", count: 100))
        book.update([turn])
        book.togglePrompt(turn.id)
        let surface = CodexBookTextSurface(book: book)
        surface.frame = content.bounds
        focus.readingView = surface
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let originalPages = surface.subviews.compactMap { $0 as? NSTextView }
        try #require(originalPages.count > 2)
        let input = CodexTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        focus.inputView = input
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.activateInput()
        book.update([CodexTurn(prompt: "短い本文")])
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(surface.subviews.compactMap { $0 as? NSTextView }.count == 1)
        #expect(originalPages.dropFirst().allSatisfy { $0.superview == nil })
        #expect(window.firstResponder === input)
        #expect(!focus.isReading(in: window))
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        surface.isHidden = true
        focus.activateReading()
        #expect(window.firstResponder === input)
    }

    @Test func readingShortcutsMoveAndReturnToDraftWithoutConsumingEditorKeys() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let focus = CodexBookFocus()
        let surface = CodexBookTextSurface(book: CodexBookDocument())
        surface.frame = content.bounds
        focus.readingView = surface
        content.addSubview(surface)
        let input = CodexTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.inputView = input
        var moves: [Int] = []
        let keys = CodexPageKeys(focus: focus, move: { moves.append($0) })
        func event(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        focus.activateReading()
        for (characters, code) in [("h", UInt16(4)), ("l", 37), ("", 123), ("", 124)] {
            #expect(keys.handle(try event(characters, code: code)))
            #expect(window.firstResponder === surface)
        }
        #expect(moves == [-1, 1, -1, 1])
        #expect(!keys.handle(try event("x", code: 7)))
        #expect(!keys.handle(try event("/", code: 44)))
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!keys.handle(try event("l", code: 37, modifiers: modifiers)))
            #expect(!keys.handle(try event(" ", code: 49, modifiers: modifiers)))
        }
        #expect(keys.handle(try event(" ", code: 49)))
        #expect(window.firstResponder === input)
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        for (characters, code) in [("h", UInt16(4)), ("l", 37), (" ", 49), ("/", 44), ("", 123), ("", 124)] {
            #expect(!keys.handle(try event(characters, code: code)))
        }
        let other = CodexBookTextSurface(book: CodexBookDocument())
        other.frame = content.bounds
        content.addSubview(other)
        #expect(window.makeFirstResponder(other))
        #expect(!keys.handle(try event("l", code: 37)))
        #expect(!keys.handle(try event(" ", code: 49)))

        let composing = ComposingInputText(frame: content.bounds)
        content.addSubview(composing)
        #expect(window.makeFirstResponder(composing))
        #expect(!keys.handle(try event("l", code: 37)))
        #expect(!keys.handle(try event(" ", code: 49)))
        #expect(window.firstResponder === composing)
        #expect(moves == [-1, 1, -1, 1])
    }

    @Test func markdownParserPreservesStructuredBlocks() throws {
        let blocks = CodexMarkdown(source: "# Heading\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet x = 1\n```\n").blocks
        try #require(blocks.count == 3)
        #expect(blocks.first?.kind == .header(level: 1))
        if case .table(let columns) = blocks[1].kind {
            #expect(columns.count == 2)
            #expect(blocks[1].children.count == 2)
        } else {
            Issue.record("Markdown table was not preserved")
        }
        #expect(blocks.last?.kind == .codeBlock(languageHint: "swift"))
    }
}

private final class ComposingInputText: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
