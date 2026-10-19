import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
import WhubClient
@testable import WhubAgent
@testable import WhubServer

@MainActor
private final class AgentAPITestAdapter: AgentAdapter {
    let kind = AgentKind.codex
    let events: AsyncStream<AgentEvent>
    private let emitter: AsyncStream<AgentEvent>.Continuation
    var sent: [[AgentInput]] = []
    var closes = 0
    var cursor: String?
    private var requests: [String: AgentRequest] = [:]
    let option = AgentModelOption(id: "model-high", modelID: "model", displayName: "Model", description: "",
                                  effort: "high", isDefaultEffort: true)
    let skill = AgentSkill(id: "/skills/example", name: "example", description: "Example")
    let entry = AgentHistoryEntry(id: "history-thread", name: "History", preview: "Preview", directory: "/workspace",
                                  updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    init() {
        let stream = AsyncStream<AgentEvent>.makeStream()
        events = stream.stream
        emitter = stream.continuation
    }

    func emit(_ event: AgentEvent) {
        if case .output(.request(let request)) = event { requests[request.id] = request }
        emitter.yield(event)
    }
    func connect(directory: String) async throws {}
    func send(_ input: [AgentInput]) async throws {
        sent.append(input)
        emit(.conversationIDChanged("live-thread"))
    }
    func sendAdditionalInput(_ input: [AgentInput]) async throws {}
    func interrupt() async throws { emit(.interrupted) }
    func loadModelOptions() async throws -> [AgentModelOption] { [option] }
    func loadSkills() async throws -> [AgentSkill] { [skill] }
    func loadStatus() async throws -> [AgentContent] { [.code("Status")] }
    func changeModel(_ option: AgentModelOption) async throws { emit(.modelOptionChanged(option)) }
    func respond(to requestID: String, with response: AgentResponse) async throws {
        guard var request = requests[requestID] else { throw AgentError(.notFound, "Unknown request") }
        switch response {
        case .approval(let allow): request.outcome = allow ? .accepted : .declined
        case .answers: request.outcome = .answered
        }
        emit(.output(.request(request)))
    }
    func loadHistory(cursor: String?) async throws -> AgentHistoryPage {
        self.cursor = cursor
        return AgentHistoryPage(entries: [entry], nextCursor: "next + 日本語/%")
    }
    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot {
        var exchange = AgentExchange(input: [.text("Restored")])
        exchange.status = .completed
        return AgentHistorySnapshot(entry: entry, exchanges: [exchange], selectedModelOption: option)
    }
    func close() { closes += 1; emitter.finish() }
}

@MainActor
private final class AgentAPITestFactory {
    var adapters: [AgentAPITestAdapter] = []

    func make(_ kind: AgentKind) throws -> any AgentAdapter {
        guard kind == .codex else { throw AgentError(.unsupported, "Not implemented") }
        let adapter = AgentAPITestAdapter()
        adapters.append(adapter)
        return adapter
    }
}

private func agentTestRouter(_ runtime: AgentRuntime) -> Router<BasicRequestContext> {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let configuration = ManagerConfiguration(environment: .dev, source: directory, swift: "/usr/bin/swift",
                                             service: "fixture", healthURL: URL(string: "http://127.0.0.1/ping")!)
    let manager = ManagerAPI(manager: ServerManager(root: directory.appendingPathComponent(".build/agent-api-tests")),
                             configuration: configuration, executable: directory, running: nil)
    return makeRouter(files: FilesAPI(), manager: manager, agent: .init(runtime: runtime))
}

private func agentState(_ client: WhubClient, id: UUID,
                        matching predicate: @Sendable (AgentSessionState) -> Bool) async throws -> AgentSessionState {
    for _ in 0..<200 {
        let state = try await client.agent.state(sessionID: id)
        if predicate(state) { return state }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentError(.adapterFailed, "Timed out waiting for state")
}

@Suite @MainActor
struct AgentAPITests {
    @Test func clientAndServerUseCommonModelsForAllOperations() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        let app = Application(router: agentTestRouter(runtime))
        try await app.test(.live) { transport in
            let port = try #require(transport.port)
            let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
            try await client.ping()
            let created = try await client.agent.create(kind: .codex, directory: "/workspace")
            let id = created.id
            #expect(try await client.agent.list().map(\.id) == [id])
            let adapter = try #require(await factory.adapters.first)
            let models = try await client.agent.models(sessionID: id)
            let skills = try await client.agent.skills(sessionID: id)
            #expect(models.count == 1 && skills.count == 1)
            #expect(try await client.agent.status(sessionID: id) == [.code("Status")])
            let history = try await client.agent.history(sessionID: id)
            #expect(history.entries.first?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))
            _ = try await client.agent.history(sessionID: id, cursor: history.nextCursor)
            #expect(await adapter.cursor == history.nextCursor)

            let change = AgentCommand(action: .changeModel(models[0]))
            _ = try await client.agent.execute(sessionID: id, command: change)
            _ = try await agentState(client, id: id) { $0.selectedModelOption == models[0] && !$0.isChangingModel }
            let image = try AgentImageAttachment(data: Data([1, 2]), mediaType: "image/png")
            let send = AgentCommand(action: .send([.text(" Hello "), .image(image), .skill(skills[0])]))
            let receipt = try await client.agent.execute(sessionID: id, command: send)
            #expect(receipt.id == send.id)
            let running = try await agentState(client, id: id) {
                $0.isRunning && $0.commands.first(where: { $0.id == send.id })?.status == .completed
            }
            #expect(running.conversationID == "live-thread")
            #expect(running.exchanges.last?.input == [.text("Hello"), .image(image), .skill(skills[0])])
            _ = try await client.agent.execute(sessionID: id, command: send)
            #expect(await adapter.sent.count == 1)

            let request = AgentRequest(id: "question", kind: .questions([
                AgentQuestion(id: "answer", prompt: "Proceed?", options: [], isSecret: false)
            ]), outcome: nil)
            await adapter.emit(.output(.request(request)))
            _ = try await agentState(client, id: id) { $0.exchanges.last?.pendingRequests.count == 1 }
            let answer = AgentCommand(action: .respond(requestID: request.id, response: .answers(["answer": "yes"])))
            _ = try await client.agent.execute(sessionID: id, command: answer)
            _ = try await agentState(client, id: id) { $0.exchanges.last?.pendingRequests.isEmpty == true }
            let approval = AgentRequest(id: "approval", kind: .approval(AgentApprovalRequest(
                reason: "Run command", command: "pwd", directory: "/workspace", changePreview: nil,
                permissionsDescription: nil, details: nil)), outcome: nil)
            await adapter.emit(.output(.request(approval)))
            _ = try await agentState(client, id: id) { $0.exchanges.last?.pendingRequests.first?.isApproval == true }
            let decline = AgentCommand(action: .respond(requestID: approval.id, response: .approval(allow: false)))
            _ = try await client.agent.execute(sessionID: id, command: decline)
            let declined = try await agentState(client, id: id) { $0.exchanges.last?.pendingRequests.isEmpty == true }
            #expect(declined.exchanges.last?.outputs.contains(where: {
                if case .request(let request) = $0 { return request.id == approval.id && request.outcome == .declined }
                return false
            }) == true)
            let additional = AgentCommand(action: .sendAdditionalInput([.text("more")]))
            _ = try await client.agent.execute(sessionID: id, command: additional)
            _ = try await agentState(client, id: id) { $0.exchanges.last?.additionalInputs.count == 1 }
            let interrupt = AgentCommand(action: .interrupt)
            _ = try await client.agent.execute(sessionID: id, command: interrupt)
            _ = try await agentState(client, id: id) { $0.exchanges.last?.status == .interrupted }

            let second = try await client.agent.create(kind: .codex, directory: "/workspace")
            let resume = AgentCommand(action: .resume(history.entries[0]))
            _ = try await client.agent.execute(sessionID: second.id, command: resume)
            let restored = try await agentState(client, id: second.id) { !$0.isResuming && $0.exchanges.count == 1 }
            #expect(restored.conversationID == history.entries[0].id)
            #expect(restored.exchanges.first?.input == [.text("Restored")])
            try await client.agent.close(sessionID: second.id)
            try await client.agent.close(sessionID: id)
            #expect(try await client.agent.list().isEmpty)
            #expect(await adapter.closes == 1)
            do {
                _ = try await client.agent.state(sessionID: id)
                Issue.record("Released session should return 404")
            } catch let error as WhubClientError {
                #expect(error == .api(status: 404, code: "notFound", message: "セッションが存在しません。"))
            }
        }
    }

    @Test func changesTimeoutAndClientCancellationDoNotStopExecution() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        try await Application(router: agentTestRouter(runtime)).test(.live) { transport in
            let port = try #require(transport.port)
            let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
            let created = try await client.agent.create(kind: .codex, directory: "/workspace")
            let idle = try await client.agent.changes(sessionID: created.id, after: created.revision)
            #expect(idle.revision == created.revision && !idle.isClosed)
            let adapter = try #require(await factory.adapters.first)
            let send = AgentCommand(action: .send([.text("work")]))
            _ = try await client.agent.execute(sessionID: created.id, command: send)
            let running = try await agentState(client, id: created.id) {
                $0.commands.first?.status == .completed && $0.conversationID != nil
            }
            let cancelled = Task { try await client.agent.changes(sessionID: created.id, after: running.revision) }
            try await Task.sleep(for: .milliseconds(20))
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                Issue.record("Cancelled request should not return normally")
            } catch {
                #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            #expect(try await client.agent.state(sessionID: created.id).isRunning)
            #expect(await adapter.closes == 0)
            await adapter.emit(.completed)
            let completed = try await client.agent.changes(sessionID: created.id, after: running.revision)
            #expect(completed.revision > running.revision && completed.exchanges.last?.status == .completed)
            try await client.agent.close(sessionID: created.id)
        }
    }

    @Test func routesRejectInvalidInputAndKeepRuntimeErrors() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        try await Application(router: agentTestRouter(runtime)).test(.router) { client in
            let headers: HTTPFields = [.contentType: "application/json"]
            for body in ["{}", "[]", #"{"kind":"other","directory":"/workspace"}"#,
                         #"{"kind":"codex","directory":42}"#, #"{"kind":"codex","directory":"relative"}"#] {
                let response = try await client.execute(uri: "/agent/sessions", method: .post, headers: headers,
                                                        body: .init(string: body))
                #expect(response.status == .badRequest)
            }
            let noContentType = try await client.execute(uri: "/agent/sessions", method: .post,
                                                         body: .init(string: #"{"kind":"codex","directory":"/workspace"}"#))
            #expect(noContentType.status == .badRequest)
            let unsupported = try await client.execute(uri: "/agent/sessions", method: .post, headers: headers,
                body: .init(string: #"{"kind":"claudeCode","directory":"/workspace"}"#))
            #expect(unsupported.status == .unprocessableContent)
            let missing = try await client.execute(uri: "/agent/sessions/\(UUID())", method: .get)
            #expect(missing.status == .notFound)
            let created = try await runtime.create(kind: .codex, directory: "/workspace")
            let path = "/agent/sessions/\(created.id)"
            for uri in ["/agent/sessions?extra=1", "/agent/sessions/not-a-uuid", path + "?extra=1",
                        path + "/changes", path + "/changes?after=-1", path + "/changes?after=1&after=2",
                        path + "/changes?after=%", path + "/changes?after=18446744073709551616",
                        path + "/history?cursor=", path + "/history?other=1"] {
                let response = try await client.execute(uri: uri, method: .get)
                #expect(response.status == .badRequest, "\(uri)")
            }
            let future = try await client.execute(uri: path + "/changes?after=1", method: .get)
            #expect(future.status == .badRequest)
            let invalidCommand = try await client.execute(uri: path + "/commands", method: .post,
                                                          headers: headers, body: .init(string: "{}"))
            #expect(invalidCommand.status == .badRequest)
            let ping = try await client.execute(uri: "/ping", method: .get)
            #expect(ping.status == .ok && String(buffer: ping.body) == "pong")
        }
    }
}
