import Foundation
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexStatusTests {
    @Test func commandResultsStayStructuredUntilPresented() async throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let session = CodexStore(context: container.mainContext)
        await session.commands.runCommand(.stop, session: session)
        let stopped = try #require(session.turns.last?.answers.first)
        guard case .noRunningTask? = stopped.output else {
            Issue.record("The store must retain the command result, not its display text")
            return
        }
        #expect(stopped.text == nil)
        #expect(stopped.displayText == "実行中の作業はありません。")
        #expect(stopped.displayMarkdown == "```\n実行中の作業はありません。\n```")

        session.appendCommandOutput(.skills, .text("value\n```\ninjected\n````"))
        let raw = try #require(session.turns.last?.answers.first)
        #expect(raw.displayText == "value\n```\ninjected\n````")
        #expect(raw.displayMarkdown.hasPrefix("`````\n"))
        #expect(raw.displayMarkdown.hasSuffix("\n`````"))
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 800, height: 450))
        book.update([try #require(session.turns.last)])
        let blocks = book.pages.flatMap(\.fragments).filter { !$0.isUser }.map(\.block)
        #expect(blocks.contains { $0.kind == .codeBlock(languageHint: nil) })
    }

    @Test func showsSessionValuesAndRemainingQuotaWithoutSecrets() {
        let output = CodexCommandPresentation.render(CodexStatusSnapshot(directory: "/project", threadID: "thread-1",
            settings: ["model": "session-model", "effort": "high", "instructionSources": ["/project/AGENTS.md"]],
            config: ["model": "default-model", "api_key": "SECRET", "model_providers": ["secret": "SECRET"]],
            account: ["type": "chatgpt", "email": "test@example.com", "planType": "pro", "accessToken": "SECRET"],
            limits: ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 0]]],
            tokenUsage: ["last": ["totalTokens": 250], "modelContextWindow": 1000], failures: []),
            timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(output.contains("session-model (reasoning high)"))
        #expect(!output.contains("default-model"))
        #expect(!output.contains("SECRET"))
        #expect(output.contains("75% left"))
        #expect(output.contains("5h limit"))
        #expect(output.contains("01/01 00:00"))
        #expect(output.contains("AGENTS.md"))
    }

    @Test func distinguishesUnknownLimitsFromZeroAndPreservesAllBuckets() {
        let output = CodexCommandPresentation.render(CodexStatusSnapshot(directory: "/project", threadID: nil, settings: [:], config: [:],
            account: nil, limits: ["rateLimitsByLimitId": [
                "one": ["primary": ["usedPercent": 100, "windowDurationMins": 10080]],
                "two": ["primary": ["usedPercent": 0, "windowDurationMins": 15]]
            ]], tokenUsage: nil, failures: [.account]))
        #expect(output.contains("one · Weekly limit"))
        #expect(output.contains("two · 15m limit"))
        #expect(output.contains("0% left"))
        #expect(output.contains("100% left"))
        #expect(output.contains("Unable to retrieve"))
        #expect(output.contains("Not started"))
        #expect(!output.contains("Context window"))
    }

    @Test func fencesCannotBeClosedByResponseText() {
        let output = CodexCommandPresentation.codeBlock("value\n```\ninjected\n````")
        #expect(output.hasPrefix("`````\n"))
        #expect(output.hasSuffix("\n`````"))
    }

    @Test func malformedConfigurationAndAPIKeyAccountNeverLeakRawResponses() async throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var methods: [String] = []
        let session = CodexStore(context: container.mainContext) { method, params, _ in
            methods.append(method)
            if method == "config/read" {
                #expect(params["cwd"] is String)
                return ["config": "SECRET", "api_key": "SECRET"]
            }
            #expect(params["refreshToken"] as? Bool == false)
            return ["account": ["type": "apiKey", "apiKey": "SECRET"]]
        }
        let snapshot = await session.commands.loadStatus(session: session)
        let text = CodexCommandPresentation.render(snapshot)
        #expect(methods == ["config/read", "account/read"])
        #expect(text.contains("Unable to retrieve"))
        #expect(text.contains("API key configured"))
        #expect(!text.contains("SECRET"))
    }
}
