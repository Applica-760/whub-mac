import Foundation

@MainActor
final class AgentSession {
    private(set) var state: AgentSessionState
    let synchronization = AgentSynchronization()
    private let adapter: any AgentAdapter
    private var observer: Task<Void, Never>?
    private var commands: [UUID: AgentCommand] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: CheckedContinuation<AgentSessionState, any Error>] = [:]
    private var configuring: Bool { state.isResuming || state.isChangingModel }

    init(directory: String, adapter: any AgentAdapter) {
        self.adapter = adapter
        state = AgentSessionState(id: UUID(), kind: adapter.kind, directory: directory, createdAt: Date())
        let events = adapter.events
        observer = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
            guard !Task.isCancelled else { return }
            self?.adapterEnded()
        }
    }

    deinit { observer?.cancel() }

    func changes(after revision: UInt64) async throws -> AgentSessionState {
        try Task.checkCancellation()
        guard revision <= state.revision else {
            throw AgentError(.invalidInput, "現在より新しい更新番号は指定できません。")
        }
        if revision < state.revision || state.isClosed { return state }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func execute(_ command: AgentCommand) throws -> AgentCommandReceipt {
        if let existing = commands[command.id] {
            guard existing == command else {
                throw AgentError(.conflict, "同じ操作IDに異なる操作を指定できません。")
            }
            return state.commands.first { $0.id == command.id }!
        }
        try requireOpen()
        try prepare(command.action)
        commands[command.id] = command
        let receipt = AgentCommandReceipt(id: command.id, status: .accepted)
        state.commands.append(receipt)
        state.error = nil
        publish()
        let exchangeID = state.exchanges.last?.id
        let outputIndex = state.exchanges.last?.outputs.count ?? 0
        tasks[command.id] = Task { [weak self] in
            await self?.perform(command, exchangeID: exchangeID, outputIndex: outputIndex)
        }
        return receipt
    }

    func models() async throws -> [AgentModelOption] {
        try requireOpen()
        do { return try await adapter.loadModelOptions() }
        catch { throw AgentError.wrapping(error) }
    }

    func skills() async throws -> [AgentSkill] {
        try requireOpen()
        do { return try await adapter.loadSkills() }
        catch { throw AgentError.wrapping(error) }
    }

    func status() async throws -> [AgentContent] {
        try requireOpen()
        do { return try await adapter.loadStatus() }
        catch { throw AgentError.wrapping(error) }
    }

    func history(cursor: String?) async throws -> AgentHistoryPage {
        try requireOpen()
        do { return try await adapter.loadHistory(cursor: cursor) }
        catch { throw AgentError.wrapping(error) }
    }

    func close() {
        guard !state.isClosed else { return }
        state.isClosed = true
        observer?.cancel()
        observer = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        adapter.close()
        finishExchange(.interrupted)
        state.isResuming = false
        state.isChangingModel = false
        state.isSendingAdditionalInput = false
        state.isStopping = false
        state.respondingRequestIDs.removeAll()
        for index in state.commands.indices where state.commands[index].status == .accepted {
            state.commands[index].status = .failed
            state.commands[index].error = AgentError(.closed, "セッションを終了しました。")
        }
        publish()
        synchronization.releaseAll()
    }

    private func prepare(_ action: AgentCommand.Action) throws {
        switch action {
        case .send(let input):
            guard !state.isRunning, !configuring else { throw conflict() }
            state.exchanges.append(AgentExchange(input: try normalized(input)))
        case .sendAdditionalInput(let input):
            guard state.isRunning, !state.isStopping, !state.isSendingAdditionalInput, !configuring else { throw conflict() }
            _ = try normalized(input)
            state.isSendingAdditionalInput = true
        case .interrupt:
            guard state.isRunning, !state.isStopping else { throw conflict() }
            state.isStopping = true
        case .respond(let id, let response):
            guard state.isRunning, !state.respondingRequestIDs.contains(id),
                  let request = state.exchanges.last?.pendingRequests.first(where: { $0.id == id }) else {
                throw AgentError(.conflict, "未回答の要求を確認できませんでした。")
            }
            switch (request.kind, response) {
            case (.approval, .approval): break
            case (.questions(let questions), .answers(let answers)):
                guard questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw AgentError(.invalidInput, "すべての質問に回答してください。")
                }
            default: throw AgentError(.invalidInput, "要求に対応する種類の回答を指定してください。")
            }
            state.respondingRequestIDs.insert(id)
        case .changeModel:
            guard !state.isRunning, !configuring else { throw conflict() }
            state.isChangingModel = true
        case .resume(let entry):
            guard state.conversationID == nil, state.exchanges.isEmpty, !configuring,
                  entry.directory == state.directory, !entry.id.isEmpty else { throw conflict() }
            state.isResuming = true
            // Reserve this conversation before awaiting the adapter, preventing duplicate live sessions.
            state.conversationID = entry.id
        }
    }

    private func perform(_ command: AgentCommand, exchangeID: UUID?, outputIndex: Int) async {
        do {
            try Task.checkCancellation()
            switch command.action {
            case .send, .sendAdditionalInput, .interrupt, .respond:
                guard state.isRunning, state.exchanges.last?.id == exchangeID else { throw conflict() }
            case .changeModel, .resume: break
            }
            switch command.action {
            case .send(let input):
                try await adapter.send(normalized(input))
                if state.isStopping, state.isRunning, state.exchanges.last?.id == exchangeID { try await adapter.interrupt() }
            case .sendAdditionalInput(let input):
                let input = try normalized(input)
                try await adapter.sendAdditionalInput(input)
                if !state.isClosed, let index = state.exchanges.firstIndex(where: { $0.id == exchangeID }) {
                    state.exchanges[index].additionalInputs.append(AgentAdditionalInput(input: input, outputIndex: outputIndex))
                }
            case .interrupt: try await adapter.interrupt()
            case .respond(let id, let response): try await adapter.respond(to: id, with: response)
            case .changeModel(let option): try await adapter.changeModel(option)
            case .resume(let entry):
                let snapshot = try await adapter.resume(entry)
                guard !state.isClosed else { return }
                guard snapshot.entry.id == entry.id, snapshot.exchanges.allSatisfy({ $0.status != .running }) else {
                    throw AgentError(.adapterFailed, "指定した会話の完了済み履歴を確認できませんでした。")
                }
                state.exchanges = snapshot.exchanges
                state.selectedModelOption = snapshot.selectedModelOption
            }
            guard !state.isClosed else { return }
            complete(command.id, error: nil)
        } catch {
            guard !state.isClosed else { return }
            let error = AgentError.wrapping(error)
            switch command.action {
            case .send, .sendAdditionalInput, .interrupt, .respond:
                if state.isRunning, state.exchanges.last?.id == exchangeID { state.error = error }
            case .changeModel, .resume:
                state.error = error
            }
            if case .send = command.action, state.exchanges.last?.id == exchangeID {
                finishExchange(.failed)
            }
            if case .resume = command.action { state.conversationID = nil }
            if case .interrupt = command.action, state.exchanges.last?.id == exchangeID { state.isStopping = false }
            complete(command.id, error: error)
        }
        switch command.action {
        case .changeModel: state.isChangingModel = false
        case .resume: state.isResuming = false
        case .sendAdditionalInput: state.isSendingAdditionalInput = false
        case .respond(let id, _): state.respondingRequestIDs.remove(id)
        case .send, .interrupt: break
        }
        tasks.removeValue(forKey: command.id)
        publish()
    }

    private func complete(_ id: UUID, error: AgentError?) {
        guard let index = state.commands.firstIndex(where: { $0.id == id }) else { return }
        state.commands[index].status = error == nil ? .completed : .failed
        state.commands[index].error = error
    }

    private func receive(_ event: AgentEvent) {
        guard !state.isClosed else { return }
        switch event {
        case .conversationIDChanged(let id): state.conversationID = id
        case .modelOptionChanged(let option): state.selectedModelOption = option
        case .output(let output):
            guard state.isRunning, let index = state.exchanges.indices.last else { return }
            if let existing = state.exchanges[index].outputs.firstIndex(where: { $0.id == output.id }) {
                state.exchanges[index].outputs[existing] = output
            } else { state.exchanges[index].outputs.append(output) }
        case .completed: finishExchange(.completed)
        case .interrupted: finishExchange(.interrupted)
        case .failed(let message):
            state.error = AgentError(.adapterFailed, message)
            finishExchange(.failed)
        }
        publish()
    }

    private func finishExchange(_ status: AgentExecutionStatus) {
        guard state.isRunning, let index = state.exchanges.indices.last else { return }
        state.exchanges[index].status = status
        for outputIndex in state.exchanges[index].outputs.indices {
            if case .request(var request) = state.exchanges[index].outputs[outputIndex], request.outcome == nil {
                request.outcome = .unanswered
                state.exchanges[index].outputs[outputIndex] = .request(request)
            }
        }
        state.isStopping = false
        state.respondingRequestIDs.removeAll()
    }

    private func adapterEnded() {
        guard !state.isClosed else { return }
        state.error = AgentError(.adapterFailed, "Agentの接続が終了しました。")
        close()
    }

    private func normalized(_ input: [AgentInput]) throws -> [AgentInput] {
        let input = input.compactMap { item -> AgentInput? in
            guard case .text(let text) = item else { return item }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
        guard !input.isEmpty else { throw AgentError(.invalidInput, "入力が空です。") }
        return input
    }

    private func requireOpen() throws {
        if state.isClosed { throw AgentError(.closed, "セッションは終了しています。") }
    }

    private func conflict() -> AgentError {
        AgentError(.conflict, "現在のセッション状態ではこの操作を実行できません。")
    }

    private func publish() {
        state.revision += 1
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: state) }
    }
}
