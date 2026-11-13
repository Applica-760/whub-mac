// テスト一覧:
// - showsSessionValuesAndRemainingLimitsWithoutPeerAddress(): [CC-F-015]
// - failuresAndUnavailableLimitsAreShownExplicitly(): [CC-F-015]

import Foundation
import Testing
@testable import WhubAgent

@Suite @MainActor
struct ClaudeCodeStatusTests {
    @Test func showsSessionValuesAndRemainingLimitsWithoutPeerAddress() {
        let snapshot = ClaudeCodeStatusSnapshot(
            status: ["sections": [["title": "Session", "rows": [
                ["label": "Version", "value": "2.1.323"],
                ["label": "Peer address", "value": "uds:/tmp/socket"],
                ["label": "cwd", "value": "/project"]
            ]]]],
            settings: ["effort": "high"], permissionMode: "default",
            context: ["totalTokens": 250, "maxTokens": 1000],
            usage: ["rate_limits_available": true,
                    "rate_limits": ["five_hour": ["utilization": 25, "resets_at": "2026-01-01T00:00:00.000Z"]],
                    "session": ["total_cost_usd": 0.5]],
            failures: [])

        let output = ClaudeCodeMapping.statusText(snapshot, timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(output.contains("2.1.323") && output.contains("/project"))
        #expect(!output.contains("Peer address") && !output.contains("uds:"))
        #expect(output.contains("high") && output.contains("default"))
        #expect(output.contains("5h limit") && output.contains("75% left") && output.contains("01/01 00:00"))
        #expect(output.contains("$0.5000"))
    }

    @Test func failuresAndUnavailableLimitsAreShownExplicitly() {
        let snapshot = ClaudeCodeStatusSnapshot(status: nil, settings: [:], permissionMode: nil, context: nil,
                                                usage: ["rate_limits_available": false], failures: [.status, .context])

        let lines = ClaudeCodeMapping.statusText(snapshot).components(separatedBy: "\n")

        #expect(lines.count == 3)
        #expect(lines.contains { $0.hasPrefix("Rate limits:") && $0.hasSuffix("Not available") })
        #expect(lines.contains { $0.hasPrefix("Status:") && $0.hasSuffix("Unable to retrieve") })
        #expect(lines.contains { $0.hasPrefix("Context window:") && $0.hasSuffix("Unable to retrieve") })
    }
}
