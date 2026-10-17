import AppKit
import Foundation
import Testing
@testable import whub

@Suite @MainActor
struct CodexAgentModelTests {
    private func model(_ name: String = "new-model") -> [String: Any] {
        ["id": "catalog-" + name, "model": name, "displayName": "Friendly " + name,
         "description": "Model description", "defaultReasoningEffort": "medium",
         "supportedReasoningEfforts": [["reasoningEffort": "medium"],
                                       ["reasoningEffort": "high", "description": "More reasoning"]]]
    }

    private func session(_ request: @escaping (String, [String: Any], String) async throws -> [String: Any]) async throws -> CodexAgentSession {
        let session = CodexAgentSession(request: request)
        try await session.connect(directory: FileManager.default.currentDirectoryPath)
        return session
    }

    @Test func catalogUsesCommonOptionsAndPreservesBothIdentifiers() throws {
        var entry = model()
        entry["inputModalities"] = ["text"]
        let parsed = try CodexAgentModel(entry)
        #expect(parsed.id == "catalog-new-model")
        #expect(!parsed.supportsImages)
        #expect(parsed.options.map(\.modelID) == ["new-model", "new-model"])
        #expect(parsed.options.map(\.description) == ["Model description", "More reasoning"])
        #expect(parsed.options.map(\.isDefaultEffort) == [true, false])
        #expect(parsed.options[1].id == CodexAgentJSON.pretty(["catalog-new-model", "high"]))
        #expect(try CodexAgentModel(model()).supportsImages)
    }

    @Test func emptyEffortListUsesDefaultAndMalformedCatalogIsRejected() throws {
        var entry = model()
        entry["supportedReasoningEfforts"] = [[String: Any]]()
        #expect(try CodexAgentModel(entry).options.map(\.effort) == ["medium"])
        #expect(throws: CodexAgentError.self) { try CodexAgentModel([:]) }
        for efforts in [[ ["reasoningEffort": "high"] ],
                        [["reasoningEffort": "medium"], ["reasoningEffort": "medium"]],
                        [["reasoningEffort": ""]]] {
            entry["supportedReasoningEfforts"] = efforts
            #expect(throws: CodexAgentError.self) { try CodexAgentModel(entry) }
        }
    }

    @Test func loadsPagesFiltersHiddenAndDeduplicatesWithoutStartingThread() async throws {
        var calls: [String] = []
        let session = try await session { method, params, directory in
            calls.append(method)
            #expect(directory == FileManager.default.currentDirectoryPath)
            if method == "config/read" { return ["config": ["model": "b", "model_reasoning_effort": "high"]] }
            #expect(method == "model/list")
            #expect(params["includeHidden"] as? Bool == false)
            if params["cursor"] == nil { return ["data": [model("a")], "nextCursor": "next"] }
            #expect(params["cursor"] as? String == "next")
            var hidden = model("hidden")
            hidden["hidden"] = true
            return ["data": [model("a"), hidden, model("b")]]
        }
        defer { session.disconnect() }
        var events = session.events.makeAsyncIterator()
        let options = try await session.loadModelOptions()
        #expect(options.map(\.modelID) == ["a", "a", "b", "b"])
        guard case .modelOptionChanged(let selection)? = await events.next() else {
            Issue.record("Configured selection was not published"); return
        }
        #expect(selection.modelID == "b" && selection.effort == "high")
        #expect(calls == ["model/list", "model/list", "config/read"])
    }

    @Test func repeatedCursorFailsWithoutReturningPartialCatalog() async throws {
        let session = try await session { _, _, _ in ["data": [model()], "nextCursor": "same"] }
        defer { session.disconnect() }
        await #expect(throws: CodexAgentError.self) { try await session.loadModelOptions() }
    }

    @Test func configuredSelectionFallsBackToServerDefaults() async throws {
        let session = try await session { method, _, _ in
            if method == "config/read" { return ["config": [:]] }
            var entry = model()
            entry["isDefault"] = true
            return ["data": [model("other"), entry]]
        }
        defer { session.disconnect() }
        var events = session.events.makeAsyncIterator()
        _ = try await session.loadModelOptions()
        guard case .modelOptionChanged(let option)? = await events.next() else {
            Issue.record("Default selection missing"); return
        }
        #expect(option.modelID == "new-model" && option.effort == "medium")
    }

    @Test func selectedOptionIsResolvedFromCatalogBeforeRPC() async throws {
        var calls: [String] = []
        var applied: [String: Any] = [:]
        let session = try await session { method, params, _ in
            calls.append(method)
            switch method {
            case "model/list": return ["data": [model()]]
            case "config/read": return ["config": ["model": "new-model"]]
            case "thread/start": return ["thread": ["id": "thread-1"]]
            case "thread/settings/update": applied = params; return [:]
            default: throw CodexAgentError(message: method)
            }
        }
        defer { session.disconnect() }
        let options = try await session.loadModelOptions()
        let forged = AgentModelOption(id: options[1].id, modelID: "forged", displayName: "forged",
                                      description: "", effort: "forged", isDefaultEffort: false)
        try await session.changeModel(forged)
        #expect(calls == ["model/list", "config/read", "thread/start", "thread/settings/update"])
        #expect(applied["threadId"] as? String == "thread-1")
        #expect(applied["model"] as? String == "new-model")
        #expect(applied["effort"] as? String == "high")
        let missing = AgentModelOption(id: "missing", modelID: "new-model", displayName: "", description: "",
                                      effort: "high", isDefaultEffort: false)
        await #expect(throws: CodexAgentError.self) { try await session.changeModel(missing) }
        #expect(calls.count == 4)
    }

    @Test func changingModelOnResumedConversationDoesNotStartInference() async throws {
        var calls: [String] = []
        let session = try await session { method, _, _ in
            calls.append(method)
            switch method {
            case "model/list": return ["data": [model()]]
            case "config/read": return ["config": ["model": "new-model"]]
            case "thread/read": return ["thread": ["id": "thread-1"]]
            case "thread/resume": return ["thread": ["id": "thread-1", "turns": [[String: Any]]()],
                                          "cwd": FileManager.default.currentDirectoryPath, "model": "old-model", "reasoningEffort": "medium"]
            case "thread/settings/update": return [:]
            default: throw CodexAgentError(message: method)
            }
        }
        defer { session.disconnect() }
        let options = try await session.loadModelOptions()
        _ = try await session.resume(testHistoryEntry())
        try await session.changeModel(options[1])
        #expect(calls == ["model/list", "config/read", "thread/read", "thread/resume", "thread/settings/update"])
    }

    @Test func disconnectedSessionRejectsLateCatalogResult() async throws {
        var reply: CheckedContinuation<[String: Any], Never>?
        let session = try await session { _, _, _ in await withCheckedContinuation { reply = $0 } }
        let loading = Task { try await session.loadModelOptions() }
        #expect(await testEventually { reply != nil })
        session.disconnect()
        reply?.resume(returning: ["data": [model()]])
        do { _ = try await loading.value; Issue.record("Late catalog accepted") } catch {}
    }

    @Test func storeKeepsSelectionAndDraftWhenModelUpdateFails() async {
        let backend = TestAgentSession()
        let old = AgentModelOption(id: "old", modelID: "old-model", displayName: "Old", description: "", effort: "medium", isDefaultEffort: true)
        let next = AgentModelOption(id: "new", modelID: "new-model", displayName: "New", description: "", effort: "high", isDefaultEffort: true)
        let store = AgentStore(kind: .codex, session: backend)
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        backend.emit(.modelOptionChanged(old))
        #expect(await testEventually { store.selectedModelOption?.id == "old" })
        store.draft = [.text("unfinished prompt")]
        backend.changeModelAction = { _ in throw CodexAgentError(message: "unsupported") }
        await store.changeModel(next)
        #expect(store.selectedModelOption?.id == "old")
        #expect(store.draft == [.text("unfinished prompt")])
        #expect(store.errorMessage == "unsupported")
        #expect(!store.isChangingModel)
    }

    @Test func storeBlocksConcurrentModelChangesAndIgnoresLateResponse() async {
        let backend = TestAgentSession()
        var reply: CheckedContinuation<Void, Never>?
        backend.changeModelAction = { _ in await withCheckedContinuation { reply = $0 } }
        let store = AgentStore(kind: .codex, session: backend)
        await store.connect(directory: "/project")
        let option = AgentModelOption(id: "new", modelID: "new", displayName: "New", description: "", effort: "high", isDefaultEffort: true)
        let changing = Task { await store.changeModel(option) }
        #expect(await testEventually { reply != nil })
        #expect(store.isChangingModel && !store.canSend)
        await store.changeModel(option)
        #expect(backend.changedOptions.count == 1)
        store.disconnect()
        backend.emit(.modelOptionChanged(option))
        reply?.resume()
        await changing.value
        #expect(store.selectedModelOption == nil)
    }

    @Test func unsupportedImagesAreNotSentAndRemainInDraft() async throws {
        var sends = 0
        let session = try await session { method, _, _ in
            if method == "model/list" {
                var entry = model()
                entry["inputModalities"] = ["text"]
                return ["data": [entry]]
            }
            if method == "config/read" { return ["config": ["model": "new-model"]] }
            sends += 1
            throw CodexAgentError(message: "Unexpected RPC")
        }
        let store = AgentStore(kind: .codex, session: session)
        defer { store.disconnect() }
        await store.connect(directory: FileManager.default.currentDirectoryPath)
        await store.loadModelOptions()
        let image = AgentImageAttachment(image: try testImage())
        store.draft = [.text("describe"), .image(image)]
        await store.send(store.draft)
        #expect(sends == 0)
        #expect(store.draft == [.text("describe"), .image(image)])
        #expect(!store.isBusy && store.errorMessage != nil)
    }
}
