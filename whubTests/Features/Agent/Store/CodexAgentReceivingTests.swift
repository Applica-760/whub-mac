import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

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
            var buffer = CodexClient.LineBuffer()
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
        let session = CodexAdapter(request: { method, params, _ in
            calls.append(method)
            switch method {
            case "thread/start": return ["thread": ["id": "thread-1"]]
            case "turn/start": return ["turn": ["id": "turn-1"]]
            case "turn/steer": steer = params; return ["turnId": "turn-1"]
            case "skills/list": return ["data": [["skills": [["name": "review", "path": "/skills/review"]]]]]
            default: throw CodexAgentError(message: method)
            }
        })
        defer { session.close() }
        try await session.connect(directory: FileManager.default.currentDirectoryPath)
        let skill = try #require(try await session.loadSkills().first)
        try await session.send([.text("first")])
        try await session.sendAdditionalInput(AgentModelMapping().input([.text("more"), .image(whub.AgentImageAttachment(image: try testImage())), .skill(skill)]))
        #expect(calls.filter { $0 == "turn/start" }.count == 1)
        #expect(steer["expectedTurnId"] as? String == "turn-1")
        let inputs = try #require(steer["input"] as? [[String: Any]])
        #expect(inputs.map { $0["type"] as? String } == ["text", "image", "skill"])
        #expect((inputs[1]["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(inputs[2]["path"] as? String == "/skills/review")
    }

    @Test func foreignThreadEventsAreIgnoredAndCompletedTurnCannotBeSteered() async throws {
        let session = CodexAdapter(request: { method, _, _ in
            method == "thread/start" ? ["thread": ["id": "thread-1"]] : ["turn": ["id": "turn-1"]]
        })
        let store = AgentStore(kind: .codex, target: testAgentTarget(session))
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
