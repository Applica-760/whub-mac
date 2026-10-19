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

@MainActor
private func agentState(_ runtime: AgentRuntime, id: UUID,
                        matching predicate: @Sendable (AgentSessionState) -> Bool) async throws -> AgentSessionState {
    for _ in 0..<200 {
        let state = try runtime.state(sessionID: id)
        if predicate(state) { return state }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentError(.adapterFailed, "Timed out waiting for state")
}

private func decodeAgent<Value: Decodable>(_ type: Value.Type, _ response: TestResponse) throws -> Value {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(type, from: Data(response.body.readableBytesView))
}

private func applyAgentChange(_ change: AgentStateChange, to document: inout AgentJSONValue,
                              path: ArraySlice<String>? = nil) throws {
    let path = path ?? change.path[...]
    if let key = path.first {
        switch document {
        case .object(var values):
            if path.count == 1 && change.operation == .remove { values.removeValue(forKey: key) }
            else {
                var value = values[key] ?? .null
                try applyAgentChange(change, to: &value, path: path.dropFirst())
                values[key] = value
            }
            document = .object(values)
        case .array(var values):
            let index = try #require(Int(key))
            #expect(values.indices.contains(index))
            try applyAgentChange(change, to: &values[index], path: path.dropFirst())
            document = .array(values)
        default: throw AgentError(.invalidInput, "Invalid patch path")
        }
        return
    }
    switch change.operation {
    case .set: document = try #require(change.value)
    case .remove: throw AgentError(.invalidInput, "Unexpected root removal")
    case .append:
        switch (document, change.value) {
        case (.array(let old), .array(let new)): document = .array(old + new)
        case (.string(let old), .string(let new)): document = .string(old + new)
        default: throw AgentError(.invalidInput, "Invalid append")
        }
    }
}

private func expectAgentState(_ actual: AgentSessionState, _ expected: AgentSessionState) throws {
    // JSON timestamps round-trip through floating-point milliseconds, unlike an in-process Date().
    let difference = abs(actual.createdAt.timeIntervalSince(expected.createdAt))
    #expect(difference < 0.000_001)
    func fields(_ state: AgentSessionState) throws -> [String: AgentJSONValue] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let value = try JSONDecoder().decode(AgentJSONValue.self, from: encoder.encode(state))
        guard case .object(var values) = value else { throw WhubClientError.invalidResponse }
        values.removeValue(forKey: "createdAt")
        return values
    }
    let matches = try fields(actual) == fields(expected)
    #expect(matches)
}

private actor AgentClientTraffic {
    var requests: [(method: String, path: String, query: String?)] = []
    var corruptNextChange = false

    func corruptChange() { corruptNextChange = true }
    func record(_ request: Request) throws -> Response? {
        requests.append((request.method.rawValue, request.uri.path, request.uri.query))
        guard corruptNextChange, request.uri.path.hasSuffix("/changes") else { return nil }
        corruptNextChange = false
        let revision = try #require(request.uri.query?.split(separator: "&").first(where: { $0.hasPrefix("after=") }))
        let after = try #require(UInt64(revision.dropFirst(6)))
        let changes = [AgentStateChange(operation: .set, path: ["directory"], value: .string("/corrupt")),
                       AgentStateChange(operation: .append, path: ["missing"], value: .string("invalid"))]
        let page = AgentTransferPage(fromRevision: after, toRevision: after + 1, cursor: 0, nextCursor: nil,
                                     data: try JSONEncoder().encode(changes))
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: .init(bytes: try JSONEncoder().encode(page))))
    }
}

private struct AgentClientTestResponder: HTTPResponder {
    let router: RouterResponder<BasicRequestContext>
    let traffic: AgentClientTraffic

    func respond(to request: Request, context: BasicRequestContext) async throws -> Response {
        if let response = try await traffic.record(request) { return response }
        return try await router.respond(to: request, context: context)
    }
}

@Suite @MainActor
struct AgentAPITests {
    @Test func commandsAndQueriesKeepExistingBehavior() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        let app = Application(router: agentTestRouter(runtime))
        try await app.test(.live) { transport in
            let port = try #require(transport.port)
            let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
            try await client.ping()
            let created = try await runtime.create(kind: .codex, directory: "/workspace")
            let id = created.id
            #expect(await runtime.summaries().map(\.id) == [id])
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
            _ = try await agentState(runtime, id: id) { $0.selectedModelOption == models[0] && !$0.isChangingModel }
            let image = try AgentImageAttachment(data: Data([1, 2]), mediaType: "image/png")
            let send = AgentCommand(action: .send([.text(" Hello "), .image(image), .skill(skills[0])]))
            let receipt = try await client.agent.execute(sessionID: id, command: send)
            #expect(receipt.id == send.id)
            let running = try await agentState(runtime, id: id) {
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
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.pendingRequests.count == 1 }
            let answer = AgentCommand(action: .respond(requestID: request.id, response: .answers(["answer": "yes"])))
            _ = try await client.agent.execute(sessionID: id, command: answer)
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.pendingRequests.isEmpty == true }
            let approval = AgentRequest(id: "approval", kind: .approval(AgentApprovalRequest(
                reason: "Run command", command: "pwd", directory: "/workspace", changePreview: nil,
                permissionsDescription: nil, details: nil)), outcome: nil)
            await adapter.emit(.output(.request(approval)))
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.pendingRequests.first?.isApproval == true }
            let decline = AgentCommand(action: .respond(requestID: approval.id, response: .approval(allow: false)))
            _ = try await client.agent.execute(sessionID: id, command: decline)
            let declined = try await agentState(runtime, id: id) { $0.exchanges.last?.pendingRequests.isEmpty == true }
            #expect(declined.exchanges.last?.outputs.contains(where: {
                if case .request(let request) = $0 { return request.id == approval.id && request.outcome == .declined }
                return false
            }) == true)
            let additional = AgentCommand(action: .sendAdditionalInput([.text("more")]))
            _ = try await client.agent.execute(sessionID: id, command: additional)
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.additionalInputs.count == 1 }
            let interrupt = AgentCommand(action: .interrupt)
            _ = try await client.agent.execute(sessionID: id, command: interrupt)
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.status == .interrupted }

            let second = try await runtime.create(kind: .codex, directory: "/workspace")
            let resume = AgentCommand(action: .resume(history.entries[0]))
            _ = try await client.agent.execute(sessionID: second.id, command: resume)
            let restored = try await agentState(runtime, id: second.id) { !$0.isResuming && $0.exchanges.count == 1 }
            #expect(restored.conversationID == history.entries[0].id)
            #expect(restored.exchanges.first?.input == [.text("Restored")])
            try await client.agent.close(sessionID: second.id)
            try await client.agent.close(sessionID: id)
            #expect(await runtime.summaries().isEmpty)
            #expect(await adapter.closes == 1)
            do {
                _ = try await client.agent.state(sessionID: id)
                Issue.record("Released session should return 404")
            } catch let error as WhubClientError {
                #expect(error == .api(status: 404, code: "notFound", message: "セッションが存在しません。"))
            }
        }
    }

    @Test func idlePollIsEmptyAndReleaseDoesNotStopSession() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        let state = try await runtime.create(kind: .codex, directory: "/workspace")
        let snapshot = try runtime.openSnapshot(sessionID: state.id)
        let path = "/agent/sessions/\(state.id)"
        try await Application(router: agentTestRouter(runtime)).test(.router) { client in
            let query = path + "/changes?snapshot=\(snapshot.id)&after=\(snapshot.revision)"
            let idle = try await client.execute(uri: query, method: .get)
            #expect(idle.status == .noContent && idle.body.readableBytes == 0)
            _ = try await runtime.execute(sessionID: state.id, command: .init(action: .send([.text("work")])))
            let running = try await agentState(runtime, id: state.id) { $0.isRunning && $0.commands.first?.status == .completed && $0.conversationID != nil }
            let current = try await runtime.openSnapshot(sessionID: state.id)
            let cancelled = Task { try await runtime.changes(sessionID: state.id, after: running.revision) }
            try await Task.sleep(for: .milliseconds(20))
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Expected cancellation") }
            catch { #expect(error is CancellationError) }
            let release = try await client.execute(uri: path + "/snapshots/\(snapshot.id)", method: .delete)
            #expect(release.status == .noContent)
            let gone = try await client.execute(uri: query, method: .get)
            #expect(gone.status == .gone)
            #expect(try await runtime.state(sessionID: state.id).isRunning)
            let adapter = try #require(await factory.adapters.first)
            #expect(await adapter.closes == 0)
            await adapter.emit(.completed)
            let finished = try await agentState(runtime, id: state.id) { !$0.isRunning }
            let changes = try await client.execute(uri: path + "/changes?snapshot=\(current.id)&after=\(current.revision)", method: .get)
            #expect(changes.status == .ok)
            let reopened = try await runtime.openSnapshot(sessionID: state.id)
            #expect(reopened.revision == finished.revision)
        }
    }

    @Test func pagedSnapshotsImagesAndDeltasReconstructState() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        try await Application(router: agentTestRouter(runtime)).test(.router) { client in
            let created = try await client.execute(uri: "/agent/sessions", method: .post,
                headers: [.contentType: "application/json"], body: .init(string: #"{"kind":"codex","directory":"/workspace"}"#))
            #expect(created.status == .created)
            let state = try decodeAgent(AgentSessionSummary.self, created)
            let path = "/agent/sessions/\(state.id)"
            let adapter = try #require(await factory.adapters.first)
            let images = try (1...2).map { try AgentImageAttachment(data: Data(repeating: UInt8($0), count: 3 * 1024 * 1024), mediaType: "image/png") }
            for (index, image) in images.enumerated() {
                let command = AgentCommand(action: .send([.image(image)]))
                let commandData = try JSONEncoder().encode(command)
                let sent = try await client.execute(uri: path + "/commands", method: .post,
                    headers: [.contentType: "application/json"], body: .init(bytes: commandData))
                #expect(sent.status == .accepted)
                _ = try await agentState(runtime, id: state.id) { $0.commands.last?.status == .completed }
                if index == 0 {
                    await adapter.emit(.completed)
                    _ = try await agentState(runtime, id: state.id) { !$0.isRunning }
                }
            }
            let longText = String(repeating: "長文😀\"\n", count: 100_000)
            let message = AgentMessage(id: "answer", role: .answer, title: "", content: .markdown(longText), status: .running)
            await adapter.emit(.output(.message(message)))
            _ = try await agentState(runtime, id: state.id) { $0.exchanges.last?.outputs.count == 1 }
            let opened = try await client.execute(uri: path + "/snapshots", method: .post)
            #expect(opened.status == .created)
            let snapshot = try decodeAgent(AgentSnapshot.self, opened)
            #expect(snapshot.byteCount > 1_048_576)
            var bytes = Data()
            var cursor = 0
            repeat {
                let response = try await client.execute(uri: path + "/snapshots/\(snapshot.id)?cursor=\(cursor)", method: .get)
                #expect(response.status == .ok && response.body.readableBytes < 1_048_576)
                let page = try decodeAgent(AgentTransferPage.self, response)
                #expect(page.fromRevision == snapshot.revision && page.toRevision == snapshot.revision)
                bytes.append(page.data)
                cursor = page.nextCursor ?? -1
                if cursor > 0 {
                    var updated = message
                    updated.content = .markdown(longText + "追記")
                    await adapter.emit(.output(.message(updated)))
                }
            } while cursor >= 0
            #expect(bytes.count == snapshot.byteCount)
            var document = try JSONDecoder().decode(AgentJSONValue.self, from: bytes)
            #expect(!String(decoding: bytes, as: UTF8.self).contains(images[0].data.prefix(32).base64EncodedString()))
            _ = try await agentState(runtime, id: state.id) {
                guard case .message(let message) = $0.exchanges.last?.outputs.last else { return false }
                return message.content == .markdown(longText + "追記")
            }
            var revision = snapshot.revision
            let latest = try await runtime.state(sessionID: state.id).revision
            while revision < latest {
                var delta = Data()
                var offset = 0
                var nextRevision = revision
                repeat {
                    let response = try await client.execute(uri: path + "/changes?snapshot=\(snapshot.id)&after=\(revision)&cursor=\(offset)", method: .get)
                    #expect(response.status == .ok)
                    let page = try decodeAgent(AgentTransferPage.self, response)
                    delta.append(page.data)
                    nextRevision = page.toRevision
                    offset = page.nextCursor ?? -1
                } while offset >= 0
                #expect(delta.count < 2048)
                for change in try JSONDecoder().decode([AgentStateChange].self, from: delta) {
                    try applyAgentChange(change, to: &document)
                }
                revision = nextRevision
            }
            let fresh = try await runtime.openSnapshot(sessionID: state.id)
            var freshBytes = Data()
            var freshCursor = 0
            repeat {
                let page = try await runtime.snapshotPage(sessionID: state.id, snapshotID: fresh.id, cursor: freshCursor)
                freshBytes.append(page.data)
                freshCursor = page.nextCursor ?? -1
            } while freshCursor >= 0
            #expect(document == (try JSONDecoder().decode(AgentJSONValue.self, from: freshBytes)))
            for image in images {
                var data = Data()
                var offset = 0
                repeat {
                    let response = try await client.execute(uri: path + "/images/\(image.id)?cursor=\(offset)", method: .get)
                    #expect(response.status == .ok && response.body.readableBytes < 1_048_576)
                    let page = try decodeAgent(AgentImagePage.self, response)
                    data.append(page.data)
                    offset = page.nextCursor ?? -1
                } while offset >= 0
                #expect(data == image.data)
            }
            for uri in ["/agent/sessions", path] {
                let response = try await client.execute(uri: uri, method: .get)
                #expect(response.status == .ok && response.body.readableBytes < 2048)
            }
            let released = try await client.execute(uri: path + "/snapshots/\(snapshot.id)", method: .delete)
            #expect(released.status == .noContent)
            #expect(try await runtime.state(sessionID: state.id).isRunning)
            #expect(await adapter.closes == 0)
            let stillAvailable = try await client.execute(uri: path + "/images/\(images[0].id)", method: .get)
            #expect(stillAvailable.status == .ok)
        }
    }

    @Test func largeDeltaPagesAndReplacementsAreLossless() async throws {
        let runtime = AgentRuntime(makeAdapter: { _ in AgentAPITestAdapter() })
        defer { runtime.shutdown() }
        var state = try await runtime.create(kind: .codex, directory: "/workspace")
        let sync = AgentSynchronization()
        let snapshot = try sync.open(state)
        var document = try JSONDecoder().decode(AgentJSONValue.self, from: sync.snapshot(snapshot.id, cursor: 0).data)
        var exchange = AgentExchange(input: [.text("Question")])
        let text = String(repeating: "長文😀\n", count: 100_000)
        exchange.outputs = [.message(.init(id: "stable", role: .answer, title: "Answer", content: .text(text), status: .running))]
        state.exchanges = [exchange]
        state.conversationID = "thread"
        state.revision += 1
        sync.publish(state)
        var changes = Data()
        var cursor = 0
        var pages = 0
        repeat {
            let page = try #require(try sync.changes(snapshot.id, after: snapshot.revision, cursor: cursor))
            changes.append(page.data)
            cursor = page.nextCursor ?? -1
            pages += 1
        } while cursor >= 0
        #expect(pages > 1)
        for change in try JSONDecoder().decode([AgentStateChange].self, from: changes) {
            try applyAgentChange(change, to: &document)
        }
        let previous = state.revision
        // Removal, non-prefix replacement, array shrinking, and exact 64-bit revision encoding.
        state.conversationID = nil
        state.exchanges[0].input = []
        state.exchanges[0].outputs[0] = .message(.init(id: "stable", role: .answer, title: "", content: .text("replacement"), status: .completed))
        state.exchanges[0].status = .completed
        state.revision = UInt64.max
        sync.publish(state)
        let delta = try #require(try sync.changes(snapshot.id, after: previous, cursor: 0))
        for change in try JSONDecoder().decode([AgentStateChange].self, from: delta.data) {
            try applyAgentChange(change, to: &document)
        }
        let fresh = try sync.open(state)
        let expected = try JSONDecoder().decode(AgentJSONValue.self, from: sync.snapshot(fresh.id, cursor: 0).data)
        #expect(document == expected)
        let restored = try JSONDecoder().decode(AgentSessionState.self, from: JSONEncoder().encode(document))
        #expect(restored.revision == UInt64.max)
    }

    @Test func prunedChangesRequireSnapshotWithoutLosingSession() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        let state = try await runtime.create(kind: .codex, directory: "/workspace")
        let snapshot = try runtime.openSnapshot(sessionID: state.id)
        // Exercise retention deterministically, without running or stopping an actual adapter.
        let synchronization = AgentSynchronization()
        var changing = state
        let view = try synchronization.open(changing)
        for index in 1...260 {
            changing.revision += 1
            changing.conversationID = "thread-\(index)"
            synchronization.publish(changing)
        }
        do {
            _ = try synchronization.changes(view.id, after: view.revision, cursor: 0)
            Issue.record("Pruned revision must require resync")
        } catch let error as AgentError { #expect(error.code == .resyncRequired) }
        let fresh = try synchronization.open(changing)
        #expect(fresh.revision == changing.revision)
        try runtime.releaseSnapshot(sessionID: state.id, snapshotID: snapshot.id)
        let reopened = try runtime.openSnapshot(sessionID: state.id)
        #expect(reopened.revision == state.revision)
        #expect(factory.adapters.first?.closes == 0)
    }

    @Test func clientCachesPagesAppliesDeltasResyncsAndDisconnects() async throws {
        let factory = AgentAPITestFactory()
        let runtime = AgentRuntime(makeAdapter: { try factory.make($0) })
        defer { runtime.shutdown() }
        let traffic = AgentClientTraffic()
        let responder = AgentClientTestResponder(router: agentTestRouter(runtime).buildResponder(), traffic: traffic)
        try await Application(responder: responder).test(.live) { transport in
            let port = try #require(transport.port)
            let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
            let created = try await client.agent.create(kind: .codex, directory: "/workspace")
            let id = created.id
            #expect(try await client.agent.list().map(\.id) == [id])
            #expect(try await client.agent.state(sessionID: id).id == id)
            let adapter = try #require(await factory.adapters.first)
            let images = try (1...2).map { try AgentImageAttachment(data: Data(repeating: UInt8($0), count: 3 * 1024 * 1024), mediaType: "image/png") }
            for (index, image) in images.enumerated() {
                _ = try await client.agent.execute(sessionID: id, command: .init(action: .send([.image(image)])))
                _ = try await agentState(runtime, id: id) { $0.commands.last?.status == .completed && $0.conversationID != nil }
                if index == 0 {
                    await adapter.emit(.completed)
                    _ = try await agentState(runtime, id: id) { !$0.isRunning }
                }
            }
            let longText = String(repeating: "長文😀\n", count: 100_000)
            var message = AgentMessage(id: "answer", role: .answer, title: "", content: .markdown(longText), status: .running)
            await adapter.emit(.output(.message(message)))
            let expected = try await agentState(runtime, id: id) { $0.exchanges.last?.outputs.count == 1 }
            let connection = try await client.agent.connect(sessionID: id)
            try expectAgentState(try await connection.state(), expected)
            let initialRequests = await traffic.requests
            let snapshotReads = initialRequests.filter { $0.path.contains("/snapshots/") && $0.method == "GET" }
            #expect(snapshotReads.count > 1)
            let imageReads = initialRequests.filter { $0.path.contains("/images/") }.count
            #expect(imageReads > 2)
            let rawSnapshot = try #require(snapshotReads.first?.path.split(separator: "/").last)
            let snapshotID = try #require(UUID(uuidString: String(rawSnapshot)))
            let idle = try await connection.update()
            try expectAgentState(idle, expected)

            message.content = .markdown(longText + "追記")
            await adapter.emit(.output(.message(message)))
            let appended = try await agentState(runtime, id: id) {
                guard case .message(let value) = $0.exchanges.last?.outputs.last else { return false }
                return value.content == .markdown(longText + "追記")
            }
            try expectAgentState(try await connection.update(), appended)
            #expect(await traffic.requests.filter { $0.path.contains("/images/") }.count == imageReads)
            #expect(await traffic.requests.filter { $0.path.contains("/snapshots/") && $0.method == "GET" }.count == snapshotReads.count)

            // An invalid second patch must not commit the valid first patch either.
            await traffic.corruptChange()
            do { _ = try await connection.update(); Issue.record("Invalid patch must fail") }
            catch let error as WhubClientError { #expect(error == .invalidResponse) }
            try expectAgentState(try await connection.state(), appended)

            try await runtime.releaseSnapshot(sessionID: id, snapshotID: snapshotID)
            let resynced = try await connection.update()
            try expectAgentState(resynced, appended)
            #expect(await traffic.requests.filter { $0.path.contains("/images/") }.count == imageReads)
            #expect(await traffic.requests.filter { $0.path.hasSuffix("/snapshots") && $0.method == "POST" }.count == 2)

            message.content = .markdown(String(repeating: "大きな差分\n", count: 150_000))
            await adapter.emit(.output(.message(message)))
            let large = try await agentState(runtime, id: id) {
                guard case .message(let value) = $0.exchanges.last?.outputs.last else { return false }
                return value.content != .markdown(longText + "追記")
            }
            let changesBefore = await traffic.requests.filter { $0.path.hasSuffix("/changes") }.count
            try expectAgentState(try await connection.update(), large)
            #expect(await traffic.requests.filter { $0.path.hasSuffix("/changes") }.count > changesBefore + 1)

            let approval = AgentRequest(id: "cached-approval", kind: .approval(.init(
                reason: "Run command", command: "pwd", directory: "/workspace", changePreview: nil,
                permissionsDescription: nil, details: nil)), outcome: nil)
            await adapter.emit(.output(.request(approval)))
            _ = try await agentState(runtime, id: id) { $0.exchanges.last?.pendingRequests.count == 1 }
            #expect(try await connection.update().exchanges.last?.pendingRequests.first == approval)
            _ = try await client.agent.execute(sessionID: id, command: .init(action: .respond(
                requestID: approval.id, response: .approval(allow: true))))
            let answered = try await agentState(runtime, id: id) {
                $0.exchanges.last?.pendingRequests.isEmpty == true && $0.commands.last?.status == .completed
            }
            try expectAgentState(try await connection.update(), answered)

            let cancelled = Task { try await connection.update() }
            try await Task.sleep(for: .milliseconds(30))
            cancelled.cancel()
            do { _ = try await cancelled.value; Issue.record("Cancelled poll must fail") }
            catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
            try expectAgentState(try await connection.state(), answered)

            let pending = Task { try await connection.update() }
            try await Task.sleep(for: .milliseconds(30))
            do { _ = try await connection.update(); Issue.record("Overlapping updates must fail") }
            catch let error as WhubClientError { #expect(error == .updateInProgress) }
            try await connection.disconnect()
            do { _ = try await pending.value; Issue.record("Disconnect must cancel polling") } catch {}
            do { _ = try await connection.state(); Issue.record("Disconnected cache must be empty") }
            catch let error as WhubClientError { #expect(error == .connectionClosed) }
            #expect(try await runtime.state(sessionID: id).isRunning)
            #expect(await adapter.closes == 0)
            #expect(await traffic.requests.filter { $0.method == "DELETE" && $0.path == "/agent/sessions/\(id)" }.isEmpty)
            let reopened = try await client.agent.connect(sessionID: id)
            try expectAgentState(try await reopened.state(), answered)
            try await reopened.disconnect()
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
            let snapshot = try await runtime.openSnapshot(sessionID: created.id)
            for suffix in ["/snapshots/\(snapshot.id)?cursor=-1", "/snapshots/\(snapshot.id)?cursor=999999", "/images/not-a-uuid",
                           "/changes?snapshot=\(snapshot.id)&after=0&cursor=-1"] {
                let response = try await client.execute(uri: path + suffix, method: .get)
                #expect(response.status == .badRequest)
            }
            let future = try await client.execute(uri: path + "/changes?snapshot=\(snapshot.id)&after=1", method: .get)
            #expect(future.status == .badRequest)
            let invalidCommand = try await client.execute(uri: path + "/commands", method: .post,
                                                          headers: headers, body: .init(string: "{}"))
            #expect(invalidCommand.status == .badRequest)
            let ping = try await client.execute(uri: "/ping", method: .get)
            #expect(ping.status == .ok && String(buffer: ping.body) == "pong")
        }
    }
}
