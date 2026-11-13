// テスト一覧:
// - optionsAddDefaultEffortBeforeSupportedLevels(): [CC-F-014]

import Testing
@testable import WhubAgent

@Suite @MainActor
struct ClaudeCodeModelTests {
    @Test func optionsAddDefaultEffortBeforeSupportedLevels() throws {
        let adjustable = try ClaudeCodeModel(["value": "opus", "displayName": "Opus", "description": "d",
                                              "supportsEffort": true, "supportedEffortLevels": ["low", "high"]])
        let fixed = try ClaudeCodeModel(["value": "haiku", "displayName": "Haiku",
                                         "supportsEffort": false, "supportedEffortLevels": ["low"]])

        #expect(adjustable.options.map(\.effort) == [nil, "low", "high"])
        #expect(adjustable.options.map(\.isDefaultEffort) == [true, false, false])
        #expect(Set(adjustable.options.map(\.id)).count == 3)
        #expect(fixed.options.map(\.effort) == [nil])
        #expect(throws: AgentError.self) { try ClaudeCodeModel(["displayName": "Missing value"]) }
    }
}
