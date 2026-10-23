import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

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
