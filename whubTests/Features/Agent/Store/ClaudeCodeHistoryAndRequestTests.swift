// テスト一覧:
// - conversationRecoversParallelToolResults(): [CC-F-005]
// - conversationFollowsLastBranchInFile(): [CC-F-006]
// - exchangesKeepSkillsAndSkipLocalCommands(): [CC-F-007]
// - interruptedExchangeMarksUnfinishedTools(): [CC-F-008]
// - historyInputConvertsImagesAndRejectsUnknownTypes(): [CC-F-009]
// - historyEntryUsesNewestNamesAndSkipsUnnamedSessions(): [CC-F-004]
// - questionsAndApprovalsKeepProtocolSpecificResponses(): [CC-F-012]
// - skillInputIsSentAsSlashCommand(): [CC-F-013]

import Foundation
import Testing
@testable import WhubAgent

@Suite @MainActor
struct ClaudeCodeHistoryAndRequestTests {
    @Test func conversationRecoversParallelToolResults() {
        let records = [
            user("u1", parent: nil, "run"),
            assistant("a1", parent: "u1", message: "m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]),
            assistant("a2", parent: "a1", message: "m1", [["type": "tool_use", "id": "t2", "name": "Read", "input": [:]]]),
            user("r1", parent: "a1", [["type": "tool_result", "tool_use_id": "t1", "content": "one"]]),
            user("r2", parent: "a2", [["type": "tool_result", "tool_use_id": "t2", "content": "two"]]),
            assistant("a3", parent: "r2", message: "m2", [["type": "text", "text": "done"]])
        ]

        let ids = ClaudeCodeHistory.conversation(records).compactMap { $0["uuid"] as? String }

        #expect(ids == ["u1", "a1", "a2", "r1", "r2", "a3"])
    }

    @Test func conversationFollowsLastBranchInFile() {
        let records = [
            user("u1", parent: nil, "first"),
            assistant("a1", parent: "u1", message: "m1", [["type": "text", "text": "answer"]]),
            user("u2", parent: "a1", "abandoned"),
            assistant("a2", parent: "u2", message: "m2", [["type": "text", "text": "old"]]),
            user("u3", parent: "a1", "retry"),
            assistant("a3", parent: "u3", message: "m3", [["type": "text", "text": "new"]]),
            ["type": "last-prompt", "lastPrompt": "abandoned", "leafUuid": "a2"]
        ]

        let ids = ClaudeCodeHistory.conversation(records).compactMap { $0["uuid"] as? String }

        #expect(ids == ["u1", "a1", "u3", "a3"])
    }

    @Test func exchangesKeepSkillsAndSkipLocalCommands() throws {
        var caveat = user("c", parent: nil, "<local-command-caveat>Caveat</local-command-caveat>")
        caveat["isMeta"] = true
        var body = user("b", parent: "s", [["type": "text", "text": "Base directory for this skill: /review"]])
        body["isMeta"] = true
        let records = [
            caveat,
            user("l", parent: "c", "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"),
            user("o", parent: "l", "<local-command-stdout>Set model</local-command-stdout>"),
            user("s", parent: "o", "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>check diff</command-args>"),
            body,
            assistant("a", parent: "b", message: "m1", [["type": "text", "text": "ok"]])
        ]

        let exchanges = try ClaudeCodeMapping.exchanges(records)

        let exchange = try #require(exchanges.first)
        #expect(exchanges.count == 1)
        #expect(exchange.input == [.skill(AgentSkill(id: "review", name: "review", description: "")), .text("check diff")])
        #expect(exchange.answers.map(\.id) == ["m1:0"])
        #expect(exchange.status == .completed)
    }

    @Test func interruptedExchangeMarksUnfinishedTools() throws {
        let records = [
            user("u1", parent: nil, "count"),
            assistant("a1", parent: "u1", message: "m1", [["type": "tool_use", "id": "t1", "name": "Bash", "input": [:]]]),
            user("i", parent: "a1", [["type": "text", "text": "[Request interrupted by user for tool use]"]]),
            user("u2", parent: "i", "next"),
            assistant("a2", parent: "u2", message: "m2", [["type": "text", "text": "AFTER"]])
        ]

        let exchanges = try ClaudeCodeMapping.exchanges(records)

        #expect(exchanges.map(\.status) == [.interrupted, .completed])
        guard case .toolUse(let tool) = try #require(exchanges.first?.outputs.first) else {
            Issue.record("Expected tool use"); return
        }
        #expect(tool.status == .interrupted)
        #expect(exchanges.last?.input == [.text("next")])
    }

    @Test func historyInputConvertsImagesAndRejectsUnknownTypes() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let image = user("u1", parent: nil, [
            ["type": "text", "text": "look"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]]
        ])

        let input = try #require(try ClaudeCodeMapping.exchanges([image]).first?.input)

        #expect(input.first == .text("look"))
        guard case .image(let attachment) = input.last else {
            Issue.record("Expected image input"); return
        }
        #expect(attachment.data == png && attachment.mediaType == "image/png")
        #expect(throws: AgentError.self) {
            try ClaudeCodeMapping.exchanges([user("u2", parent: nil, [["type": "document"]])])
        }
    }

    @Test func historyEntryUsesNewestNamesAndSkipsUnnamedSessions() throws {
        let date = Date(timeIntervalSince1970: 0)
        let head: [[String: Any]] = [["type": "ai-title", "aiTitle": "Old"], ["type": "last-prompt", "lastPrompt": "first"]]
        let tail: [[String: Any]] = [["type": "ai-title", "aiTitle": "Auto"], ["type": "custom-title", "customTitle": "Named"],
                                     ["type": "last-prompt", "lastPrompt": "latest"]]

        let named = try #require(ClaudeCodeMapping.historyEntry(id: "s1", directory: "/p", updatedAt: date, head: head, tail: tail))
        let generated = try #require(ClaudeCodeMapping.historyEntry(id: "s2", directory: "/p", updatedAt: date, head: head,
                                                                    tail: [["type": "ai-title", "aiTitle": "Auto"]]))
        let unnamed = ClaudeCodeMapping.historyEntry(id: "s3", directory: "/p", updatedAt: date,
                                                    head: [user("u", parent: nil, "hello")], tail: [])

        #expect(named.name == "Named" && named.preview == "latest")
        #expect(generated.name == "Auto" && generated.preview == "first")
        #expect(unnamed == nil)
    }

    @Test func questionsAndApprovalsKeepProtocolSpecificResponses() throws {
        let questionInput: [String: Any] = ["questions": [["question": "Which?", "header": "Pick", "multiSelect": true,
            "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]
        let writeInput: [String: Any] = ["file_path": "/a", "content": "x"]
        let question = try ClaudeCodeMapping.request(["tool_name": "AskUserQuestion", "input": questionInput], controlID: "c1")
        let approval = try ClaudeCodeMapping.request(["tool_name": "Write", "display_name": "Write", "input": writeInput], controlID: "c2")

        let answered = try ClaudeCodeMapping.response(.answers(["Which?": "A, B"]), to: question, input: questionInput)
        let allowed = try ClaudeCodeMapping.response(.approval(allow: true), to: approval, input: writeInput)
        let denied = try ClaudeCodeMapping.response(.approval(allow: false), to: approval, input: writeInput)

        guard case .questions(let questions) = question.kind else {
            Issue.record("Expected questions"); return
        }
        #expect(question.id == "request:c1" && questions.first?.isMultiSelect == true)
        #expect((answered.result["updatedInput"] as? [String: Any])?["answers"] as? [String: String] == ["Which?": "A, B"])
        #expect(answered.outcome == .answered)
        #expect(allowed.result["behavior"] as? String == "allow" && allowed.outcome == .accepted)
        #expect((allowed.result["updatedInput"] as? [String: Any])?["file_path"] as? String == "/a")
        #expect(denied.result["behavior"] as? String == "deny" && denied.outcome == .declined)
        #expect(throws: AgentError.self) {
            try ClaudeCodeMapping.response(.answers(["Which?": " "]), to: question, input: questionInput)
        }
    }

    @Test func skillInputIsSentAsSlashCommand() throws {
        let review = AgentSkill(id: "review", name: "review", description: "")
        let simplify = AgentSkill(id: "simplify", name: "simplify", description: "")

        let payload = try ClaudeCodeMapping.input([.text("$review check diff"), .skill(review)], skills: [review, simplify])

        #expect(payload.first?["text"] as? String == "/review check diff")
        #expect(throws: AgentError.self) {
            try ClaudeCodeMapping.input([.skill(review), .skill(simplify)], skills: [review, simplify])
        }
        #expect(throws: AgentError.self) {
            try ClaudeCodeMapping.input([.skill(review)], skills: [])
        }
    }

    private func user(_ id: String, parent: String?, _ content: Any) -> [String: Any] {
        ["type": "user", "uuid": id, "parentUuid": parent as Any, "message": ["role": "user", "content": content]]
    }

    private func assistant(_ id: String, parent: String, message: String, _ content: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "uuid": id, "parentUuid": parent, "message": ["id": message, "role": "assistant", "content": content]]
    }
}
