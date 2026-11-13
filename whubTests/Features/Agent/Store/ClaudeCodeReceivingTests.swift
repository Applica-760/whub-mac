// テスト一覧:
// - streamedTextIsReplacedByCompletedAssistant(): [CC-F-001]
// - toolResultCompletesMatchingToolUse(): [CC-F-002]

import Testing
@testable import WhubAgent

@Suite @MainActor
struct ClaudeCodeReceivingTests {
    @Test func streamedTextIsReplacedByCompletedAssistant() throws {
        var turn = ClaudeCodeTurn()

        _ = turn.stream(["type": "message_start", "message": ["id": "m1"]])
        _ = turn.stream(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
        _ = turn.stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hel"]])
        _ = turn.complete(["id": "m1", "content": [["type": "text", "text": "Hello"]]])
        turn.inferFinalAnswerIfNeeded()

        let item = try #require(turn.items.first)
        #expect(turn.items.count == 1)
        #expect(item.text == "Hello")
        #expect(item.status == .completed && item.isAnswer)
    }

    @Test func toolResultCompletesMatchingToolUse() {
        var turn = ClaudeCodeTurn()
        _ = turn.complete(["id": "m1", "content": [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]],
            ["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "/a"]]
        ]])

        let completed = [
            turn.completeTool(["tool_use_id": "t2", "content": "missing", "is_error": true]),
            turn.completeTool(["tool_use_id": "t1", "content": [["type": "text", "text": "a.txt"]]]),
            turn.completeTool(["tool_use_id": "unknown", "content": "x"])
        ]

        #expect(completed == ["t2", "t1", nil])
        #expect(turn.items.map(\.status) == [.completed, .failed])
        #expect(turn.items.map(\.result) == ["a.txt", "missing"])
    }
}
