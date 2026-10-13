import AppKit
import Foundation
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexModelTests {
    private func model(_ name: String = "new-model") -> [String: Any] {
        ["id": name, "model": name, "displayName": name, "defaultReasoningEffort": "medium",
         "supportedReasoningEfforts": [["reasoningEffort": "medium"], ["reasoningEffort": "high"]]]
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func thread() -> [String: Any] {
        ["thread": ["id": "thread-1", "turns": [[String: Any]]()], "cwd": "/project",
         "model": "old-model", "reasoningEffort": "medium"]
    }

    @Test func onlyWholeModelCommandOpensPicker() {
        #expect(CodexInputView.isModelInput(" /model \n"))
        #expect(!CodexInputView.isModelInput("/model explain"))
        #expect(!CodexInputView.isModelInput("explain /model"))
    }

    @Test func validatesCatalogAndPreservesServerIdentifiers() throws {
        var entry = model()
        entry["displayName"] = "Friendly name"
        entry["inputModalities"] = ["text"]
        let parsed = try CodexModel(entry)
        #expect(!parsed.supportsImages)
        #expect(parsed.parameters(threadID: "t", effort: "high")["model"] as? String == "new-model")
        #expect(try CodexModel(model()).supportsImages)
        entry["defaultReasoningEffort"] = "unsupported"
        #expect(throws: CodexError.self) { try CodexModel(entry) }
        #expect(throws: CodexError.self) { try CodexModel([:]) }
    }

    @Test func loadsPagesFiltersHiddenAndDeduplicates() async {
        var calls = 0
        let commands = CodexCommandsStore { method, params, _ in
            #expect(method == "model/list")
            #expect(params["includeHidden"] as? Bool == false)
            calls += 1
            if calls == 1 { return ["data": [model("a")], "nextCursor": "next"] }
            #expect(params["cursor"] as? String == "next")
            var hidden = model("hidden")
            hidden["hidden"] = true
            return ["data": [model("a"), hidden, model("b")]]
        }
        await commands.loadModels(directory: "/project")
        #expect(commands.models.map(\.id) == ["a", "b"])
        #expect(commands.modelError == nil)
        #expect(!commands.isLoadingModels)
    }

    @Test func repeatedCursorFailsWithoutPartialCatalog() async {
        let commands = CodexCommandsStore { _, _, _ in ["data": [model()], "nextCursor": "same"] }
        await commands.loadModels(directory: "/project")
        #expect(commands.models.isEmpty)
        #expect(commands.modelError != nil)
        #expect(!commands.isLoadingModels)
    }

    @Test func invalidatedLoadCannotRestoreStaleChoices() async {
        var continuation: CheckedContinuation<[String: Any], Never>?
        let commands = CodexCommandsStore { _, _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let task = Task { await commands.loadModels(directory: "/project") }
        while continuation == nil { await Task.yield() }
        commands.invalidate()
        continuation?.resume(returning: ["data": [model()]])
        await task.value
        #expect(commands.models.isEmpty)
        #expect(!commands.isLoadingModels)
    }

    @Test func updatesExistingThreadWithoutStartingInferenceOrWritingDefaults() async throws {
        let context = try container()
        var calls: [String] = []
        let session = CodexStore(context: context.mainContext) { method, params, _ in
            calls.append(method)
            #expect(params["threadId"] as? String == "thread-1")
            #expect(params["model"] as? String == "new-model")
            #expect(params["effort"] as? String == "high")
            return [:]
        }
        try session.restoreHistory(thread(), expectedID: "thread-1")
        try await session.changeModel(CodexModel(model()), effort: "high")
        #expect(calls == ["thread/settings/update"])
        #expect(session.model == "new-model")
        #expect(session.settings["effort"] as? String == "high")
        #expect(!session.isChangingModel)
    }

    @Test func failedUpdateRetainsCurrentSettingsAndDraft() async throws {
        let context = try container()
        let session = CodexStore(context: context.mainContext) { _, _, _ in throw CodexError(message: "unsupported") }
        try session.restoreHistory(thread(), expectedID: "thread-1")
        session.draft = "/model"
        #expect(await session.commands.applyModel(try CodexModel(model()), effort: "high", session: session) == false)
        #expect(session.model == "old-model")
        #expect(session.settings["effort"] as? String == "medium")
        #expect(session.commands.modelError == "unsupported")
        #expect(session.draft == "/model")
        #expect(session.turns.isEmpty)
    }

    @Test func reconnectRestoresSelectionAndNewConversationClearsIt() async throws {
        let context = try container()
        var calls: [String] = []
        let session = CodexStore(context: context.mainContext) { method, params, _ in
            calls.append(method)
            if method == "thread/resume" {
                #expect(params["model"] as? String == "old-model")
                #expect((params["config"] as? [String: String])?["model_reasoning_effort"] == "medium")
                return thread()
            }
            return [:]
        }
        try session.restoreHistory(thread(), expectedID: "thread-1")
        session.disconnect()
        try await session.changeModel(CodexModel(model()), effort: "high")
        #expect(calls == ["thread/resume", "thread/settings/update"])
        session.reset()
        #expect(session.threadID == nil)
        #expect(session.settings.isEmpty)
        #expect(session.model == "Codexの既存設定")
    }

    @Test func notificationsUpdateIdleSessionAndIgnoreOtherThreads() throws {
        let context = try container()
        let session = CodexStore(context: context.mainContext)
        try session.restoreHistory(thread(), expectedID: "thread-1")
        session.receive("thread/settings/updated", params: ["threadId": "other", "threadSettings": ["model": "wrong"]], requestID: nil)
        #expect(session.model == "old-model")
        session.receive("thread/settings/updated", params: ["threadId": "thread-1", "threadSettings": ["model": "server-model", "effort": "high"]], requestID: nil)
        #expect(session.model == "server-model")
        session.receive("thread/tokenUsage/updated", params: ["threadId": "thread-1", "tokenUsage": ["modelContextWindow": 1000]], requestID: nil)
        #expect(session.tokenUsage?["modelContextWindow"] as? Int == 1000)
    }

    @Test func firstSelectionCreatesThreadAndPreventsConcurrentChanges() async throws {
        let context = try container()
        var continuation: CheckedContinuation<[String: Any], Never>?
        var calls: [String] = []
        let session = CodexStore(context: context.mainContext) { method, _, _ in
            calls.append(method)
            if method == "thread/start" { return thread() }
            return await withCheckedContinuation { continuation = $0 }
        }
        session.draft = "draft"
        let choice = try CodexModel(model())
        let task = Task { try await session.changeModel(choice, effort: "high") }
        while continuation == nil { await Task.yield() }
        #expect(session.isChangingModel)
        #expect(!session.canSend)
        session.reset()
        #expect(session.threadID == "thread-1")
        do {
            try await session.changeModel(choice, effort: "medium")
            Issue.record("Concurrent update was accepted")
        } catch {}
        continuation?.resume(returning: [:])
        try await task.value
        #expect(calls == ["thread/start", "thread/settings/update"])
        #expect(session.model == "new-model")
        #expect(session.draft == "draft")
    }

    @Test func closedSessionIgnoresLateModelUpdate() async throws {
        let context = try container()
        var continuation: CheckedContinuation<[String: Any], Never>?
        let session = CodexStore(context: context.mainContext) { _, _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        try session.restoreHistory(thread(), expectedID: "thread-1")
        let choice = try CodexModel(model())
        let task = Task { try await session.changeModel(choice, effort: "high") }
        while continuation == nil { await Task.yield() }
        session.disconnect()
        continuation?.resume(returning: [:])
        do {
            try await task.value
            Issue.record("Closed session accepted a late update")
        } catch {}
        #expect(session.model == "old-model")
        #expect(session.turns.isEmpty)
    }

    @Test func unsupportedImagesStayInDraftWithoutSending() async throws {
        let context = try container()
        var calls = 0
        let session = CodexStore(context: context.mainContext) { _, _, _ in
            calls += 1
            return [:]
        }
        var response = thread()
        response["cwd"] = FileManager.default.currentDirectoryPath
        try session.restoreHistory(response, expectedID: "thread-1")
        var entry = model("old-model")
        entry["inputModalities"] = ["text"]
        session.commands.models = [try CodexModel(entry)]
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        session.addImages([image])
        #expect(session.draftImages.count == 1)
        session.draft = "describe"
        await session.send()
        #expect(calls == 0)
        #expect(session.draft == "describe")
        #expect(session.draftImages.count == 1)
        #expect(session.errorMessage != nil)
    }

    @Test func extractedSkillsAndResumeListsKeepExistingFiltering() async throws {
        let commands = CodexCommandsStore { method, _, _ in
            if method == "skills/list" {
                return ["data": [["skills": [
                    ["name": "visible", "path": "/skill", "enabled": true],
                    ["name": "hidden", "path": "/hidden", "enabled": false]
                ]]]]
            }
            return ["data": [["id": "thread-1", "cwd": "/project", "updatedAt": 1.0, "preview": "hello"]]]
        }
        await commands.loadSkills(directory: "/project")
        await commands.loadRecentThreads(directory: "/project")
        #expect(commands.skills.map(\.name) == ["visible"])
        #expect(commands.recentThreads.map(\.displayTitle) == ["hello"])
    }
}
