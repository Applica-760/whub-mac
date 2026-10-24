import Foundation
import SwiftUI
import Testing
@testable import WhubAgent
@testable import whub

@Suite @MainActor
struct CodexAgentStatusTests {
    @Test func commandResultsUseCommonStructuredContent() async throws {
        let store = AgentStore(kind: .codex, target: testAgentTarget(TestAgentSession()))
        defer { store.disconnect() }
        await store.interrupt(recordResult: true)
        let output = try #require(store.exchanges.last?.answers.first)
        guard case .slashCommandResult(let result) = output else {
            Issue.record("Expected structured command result"); return
        }
        #expect(result.command == .stop)
        #expect(result.content == [.text("実行中の作業はありません。")])
        let source = "value\n```\ninjected\n````"
        let markdown = whub.AgentContent.code(source).agentBookMarkdown
        #expect(markdown.hasPrefix("`````\n") && markdown.hasSuffix("\n`````"))
        let document = MarkdownDocument(source: markdown, width: 600, colorScheme: .dark)
        #expect(document.codes.map(\.text).joined().trimmingCharacters(in: .newlines) == source)
    }

    @Test func showsSessionValuesAndRemainingQuotaWithoutSecrets() {
        let output = CodexMapping.statusText(CodexAgentStatusSnapshot(directory: "/project", threadID: "thread-1",
            settings: ["model": "session-model", "effort": "high", "instructionSources": ["/project/AGENTS.md"]],
            config: ["model": "default-model", "api_key": "SECRET", "model_providers": ["secret": "SECRET"]],
            account: ["type": "chatgpt", "email": "test@example.com", "planType": "pro", "accessToken": "SECRET"],
            limits: ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 0]]],
            tokenUsage: ["last": ["totalTokens": 250], "modelContextWindow": 1000], failures: []),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(output.contains("session-model (reasoning high)"))
        #expect(!output.contains("default-model") && !output.contains("SECRET"))
        #expect(output.contains("75% left") && output.contains("5h limit"))
        #expect(output.contains("01/01 00:00") && output.contains("AGENTS.md"))
    }

    @Test func distinguishesUnknownLimitsFromZeroAndPreservesAllBuckets() {
        let output = CodexMapping.statusText(CodexAgentStatusSnapshot(directory: "/project", threadID: nil, settings: [:], config: [:],
            account: nil, limits: ["rateLimitsByLimitId": [
                "one": ["primary": ["usedPercent": 100, "windowDurationMins": 10080]],
                "two": ["primary": ["usedPercent": 0, "windowDurationMins": 15]]
            ]], tokenUsage: nil, failures: [.account]))
        #expect(output.contains("one · Weekly limit") && output.contains("two · 15m limit"))
        #expect(output.contains("0% left") && output.contains("100% left"))
        #expect(output.contains("Unable to retrieve") && output.contains("Not started"))
        #expect(!output.contains("Context window"))
    }

    @Test func malformedConfigurationAndAPIKeyAccountNeverLeakRawResponses() async throws {
        var calls: [String] = []
        let session = CodexAdapter(request: { method, params, _ in
            calls.append(method)
            if method == "config/read" {
                #expect(params["cwd"] is String)
                return ["config": "SECRET", "api_key": "SECRET"]
            }
            #expect(method == "account/read" && params["refreshToken"] as? Bool == false)
            return ["account": ["type": "apiKey", "apiKey": "SECRET"]]
        })
        defer { session.close() }
        try await session.connect(directory: FileManager.default.currentDirectoryPath)
        let content = try await session.loadStatus()
        guard case .code(let text) = try #require(content.first) else {
            Issue.record("Status must be formatted common content"); return
        }
        #expect(calls == ["config/read", "account/read"])
        #expect(text.contains("Unable to retrieve") && text.contains("API key configured"))
        #expect(!text.contains("SECRET"))
    }

    @Test func statusFailuresKeepAvailableInformationAndStoreRecordsResult() async throws {
        let session = CodexAdapter(request: { method, _, _ in
            switch method {
            case "config/read": return ["config": ["model": "configured"]]
            case "account/read": return ["account": ["type": "chatgpt"]]
            default: throw CodexAgentError(message: "SECRET network detail")
            }
        })
        defer { session.close() }
        let store = AgentStore(kind: .codex, target: testAgentTarget(session))
        await store.connect(directory: FileManager.default.currentDirectoryPath)
        await store.loadStatus(recordResult: true)
        let text = store.statusContent.map(\.agentBookText).joined()
        #expect(text.contains("configured") && text.contains("Unable to retrieve"))
        #expect(!text.contains("SECRET"))
        let output = try #require(store.exchanges.last?.answers.first)
        guard case .slashCommandResult(let result) = output else { Issue.record("Missing status result"); return }
        #expect(result.command == .status && result.content == store.statusContent)
        #expect(!store.isLoadingStatus)
        store.disconnect()
    }
}
