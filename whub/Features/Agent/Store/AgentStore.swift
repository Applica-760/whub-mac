import Combine
import Foundation
import WhubAgent
import WhubClient

@MainActor
final class AgentStore: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft: [AgentInput] = []
    @Published private(set) var exchanges: [AgentExchange] = []
    @Published private(set) var historyEntry: AgentHistoryEntry?
    @Published private(set) var modelOptions: [AgentModelOption] = []
    @Published private(set) var isLoadingModelOptions = false
    @Published private(set) var modelOptionsError: String?
    @Published private(set) var statusContent: [AgentContent] = []
    @Published private(set) var isLoadingStatus = false
    @Published private(set) var isConnecting = false

    @Published private var state: AgentSessionState?
    @Published private var isDisconnected = false
    @Published private var isTransportDisconnected = false
    @Published private var operationError: String?

    let agentKind: AgentKind
    var conversationID: String? { state?.conversationID }
    var directory: String? { state?.directory }
    var selectedModelOption: AgentModelOption? { state?.selectedModelOption }
    var isConnected: Bool { !isDisconnected && !isTransportDisconnected && state?.isClosed == false }
    var isClosed: Bool { isDisconnected || state?.isClosed == true }
    var isBusy: Bool { isConnected && state?.isRunning == true }
    var isResuming: Bool { isConnected && state?.isResuming == true }
    var isChangingModel: Bool { isConnected && state?.isChangingModel == true }
    var isStopping: Bool { isConnected && state?.isStopping == true }
    var isSendingAdditionalInput: Bool { isConnected && state?.isSendingAdditionalInput == true }
    var respondingRequestIDs: Set<String> { isConnected ? state?.respondingRequestIDs ?? [] : [] }
    var errorMessage: String? { operationError ?? state?.error?.localizedDescription }

    var pendingSendExchangeID: AgentExchange.ID? {
        guard let pendingSendID, let state,
              state.commands.contains(where: { $0.id == pendingSendID }) else { return nil }
        return state.exchanges.last?.id
    }

    var canSend: Bool {
        !isClosed && isConnected && !isBusy && !isChangingModel && !isResuming
    }

    let target: AgentExecutionTarget
    private var activeSessionID: UUID?
    private var remoteConnection: AgentSessionConnection?
    private let mapping = AgentModelMapping()
    private var eventTask: Task<Void, Never>?
    private var pendingInput: [AgentInput]?
    private var pendingSendID: UUID?
    private var commandResults: [(after: UUID?, exchange: AgentExchange)] = []

    init(kind: AgentKind, target: AgentExecutionTarget) {
        agentKind = kind
        self.target = target
    }

    deinit { eventTask?.cancel() }

    func connect(directory: String, reconnect: Bool = false, resuming entry: AgentHistoryEntry? = nil) async {
        if reconnect, target.keepsExecutionOnDisconnect, !isClosed, !isConnecting {
            streamEnded(nil)
        }
        guard !isClosed, !isConnecting, !isConnected else { return }
        isConnecting = true
        operationError = nil
        defer { isConnecting = false }
        do {
            let id: UUID
            if let activeSessionID { id = activeSessionID }
            else {
                id = try await target.create(kind: agentKind, directory: directory, resuming: entry)
                activeSessionID = id
            }
            guard !isClosed else {
                target.disconnect(sessionID: id, connection: nil)
                return
            }
            let (initial, connection) = try await target.snapshot(sessionID: id)
            guard !isClosed else {
                target.disconnect(sessionID: id, connection: connection)
                return
            }
            remoteConnection = connection
            isTransportDisconnected = false
            try apply(initial)
            observe(sessionID: id, after: initial.revision)
        } catch {
            guard !isClosed else { return }
            if let id = activeSessionID {
                target.disconnect(sessionID: id, connection: remoteConnection)
                remoteConnection = nil
                if !target.keepsExecutionOnDisconnect { activeSessionID = nil }
            }
            isTransportDisconnected = true
            operationError = error.localizedDescription
        }
    }

    @discardableResult
    func resume(_ entry: AgentHistoryEntry) async -> Bool {
        guard !isClosed, !isConnected, !isConnecting, !isResuming,
              historyEntry == nil, exchanges.isEmpty else { return false }
        operationError = nil
        await connect(directory: entry.directory, resuming: entry)
        guard isConnected else { return false }
        do {
            if state?.conversationID != entry.id {
                try await perform(AgentCommand(action: .resume(entry)))
            }
            guard !isClosed else { return false }
            historyEntry = entry
            return true
        } catch {
            guard !isClosed else { return false }
            operationError = error.localizedDescription
            disconnect()
            return false
        }
    }

    func send(_ input: [AgentInput]) async {
        guard canSend else { return }
        let input = normalized(input)
        guard !input.isEmpty else { return }
        let commandID = UUID()
        pendingInput = input
        pendingSendID = commandID
        draft = []
        operationError = nil
        do {
            try await perform(AgentCommand(id: commandID, action: .send(try mapping.input(input))))
        } catch {
            guard !isClosed, pendingSendID == commandID else { return }
            operationError = error.localizedDescription
            restoreInput()
        }
    }

    @discardableResult
    func sendAdditionalInput(_ input: [AgentInput]) async -> Bool {
        guard isConnected, isBusy, !isStopping, !isSendingAdditionalInput else { return false }
        let input = normalized(input)
        guard !input.isEmpty else { return false }
        let exchangeID = state?.exchanges.last?.id
        operationError = nil
        do {
            try await perform(AgentCommand(action: .sendAdditionalInput(try mapping.input(input))))
            return !isClosed
        } catch {
            guard isActiveExchange(exchangeID) else { return false }
            operationError = error.localizedDescription
            return false
        }
    }

    func interrupt(recordResult: Bool = false) async {
        if recordResult, !isBusy {
            recordCommandResult(.stop, content: [.text("実行中の作業はありません。")])
            return
        }
        if recordResult, isStopping {
            recordCommandResult(.stop, content: [.text("停止を要求しました。")])
            return
        }
        guard isConnected, isBusy, !isStopping else { return }
        let exchangeID = state?.exchanges.last?.id
        operationError = nil
        do {
            try await perform(AgentCommand(action: .interrupt))
            guard !isClosed else { return }
            if recordResult {
                recordCommandResult(.stop, content: [.text(isStopping ? "停止を要求しました。" : "作業を停止しました。")])
            }
        } catch {
            guard isActiveExchange(exchangeID) else { return }
            operationError = error.localizedDescription
            if recordResult { recordCommandResult(.stop, content: [.text(error.localizedDescription)], failed: true) }
        }
    }

    func loadModelOptions() async {
        guard isConnected, !isResuming, !isLoadingModelOptions else { return }
        isLoadingModelOptions = true
        modelOptionsError = nil
        operationError = nil
        defer { isLoadingModelOptions = false }
        do {
            let options = try await target.models(sessionID: sessionID())
            guard !isClosed else { return }
            modelOptions = options
        } catch {
            guard !isClosed else { return }
            modelOptionsError = error.localizedDescription
            operationError = error.localizedDescription
        }
    }

    func loadStatus(recordResult: Bool = false) async {
        guard isConnected, !isResuming, !isLoadingStatus else { return }
        isLoadingStatus = true
        operationError = nil
        defer { isLoadingStatus = false }
        do {
            let loaded = try await target.status(sessionID: sessionID())
            let content = try loaded.map(mapping.content)
            guard !isClosed else { return }
            statusContent = content
            if recordResult { recordCommandResult(.status, content: content) }
        } catch {
            guard !isClosed else { return }
            operationError = error.localizedDescription
            if recordResult { recordCommandResult(.status, content: [.text(error.localizedDescription)], failed: true) }
        }
    }

    func changeModel(_ option: AgentModelOption) async {
        guard isConnected, !isBusy, !isChangingModel, !isResuming else { return }
        operationError = nil
        do { try await perform(AgentCommand(action: .changeModel(option))) }
        catch {
            guard !isClosed else { return }
            operationError = error.localizedDescription
        }
    }

    func respond(to requestID: String, with response: AgentResponse) async {
        guard isConnected, !respondingRequestIDs.contains(requestID),
              state?.exchanges.last?.pendingRequests.contains(where: { $0.id == requestID }) == true else { return }
        let exchangeID = state?.exchanges.last?.id
        operationError = nil
        do { try await perform(AgentCommand(action: .respond(requestID: requestID, response: response))) }
        catch {
            guard isActiveExchange(exchangeID) else { return }
            operationError = error.localizedDescription
        }
    }

    func disconnect() {
        guard !isDisconnected else { return }
        let wasRunning = isBusy
        isDisconnected = true
        isConnecting = false
        eventTask?.cancel()
        if let id = activeSessionID {
            target.disconnect(sessionID: id, connection: remoteConnection)
        }
        remoteConnection = nil
        if wasRunning {
            operationError = "接続を終了しました。"
            restoreInput()
        }
    }

    func loadHistory(cursor: String?) async throws -> AgentHistoryPage {
        try await target.history(sessionID: sessionID(), cursor: cursor)
    }

    func loadSkills() async throws -> [AgentSkill] {
        try await target.skills(sessionID: sessionID())
    }

    private func sessionID() throws -> UUID {
        guard !isClosed, isConnected, let state else { throw AgentError(.closed, "接続されていません。") }
        return state.id
    }

    private func perform(_ command: AgentCommand) async throws {
        let id = try sessionID()
        _ = try await target.execute(sessionID: id, command: command)
        for await (latest, disconnected, transportDisconnected) in $state.combineLatest($isDisconnected, $isTransportDisconnected).values {
            guard !disconnected, !transportDisconnected, latest?.isClosed != true else {
                throw AgentError(.closed, operationError ?? "接続を終了しました。")
            }
            guard let receipt = latest?.commands.first(where: { $0.id == command.id }) else { continue }
            switch receipt.status {
            case .completed: return
            case .failed: throw receipt.error ?? AgentError(.adapterFailed, "操作を完了できませんでした。")
            case .accepted: continue
            }
        }
        throw CancellationError()
    }

    private func observe(sessionID: UUID, after revision: UInt64) {
        eventTask = Task { [weak self, target, remoteConnection] in
            var revision = revision
            do {
                while !Task.isCancelled {
                    let state = try await target.changes(sessionID: sessionID, after: revision, connection: remoteConnection)
                    guard !Task.isCancelled, self?.isClosed == false else { return }
                    try self?.apply(state)
                    revision = state.revision
                    if state.isClosed { self?.streamEnded(state.error); return }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.streamEnded(error)
            }
        }
    }

    private func apply(_ next: AgentSessionState) throws {
        guard !isDisconnected else { return }
        if let state, next.revision <= state.revision { return }
        let mapped = try mapping.exchanges(next.exchanges)
        state = next
        // Notify observers before releasing the send's identity.
        exchanges = merged(mapped)
        if let pendingSendID, next.commands.contains(where: { $0.id == pendingSendID }),
           let exchange = next.exchanges.last, exchange.status != .running {
            if exchange.status == .completed { pendingInput = nil; self.pendingSendID = nil }
            else { restoreInput() }
        }
    }

    private func streamEnded(_ error: (any Error)?) {
        let message = error?.localizedDescription ?? "エージェントとの接続が終了しました。"
        if target.keepsExecutionOnDisconnect {
            operationError = message
            eventTask?.cancel()
            if let id = activeSessionID { target.disconnect(sessionID: id, connection: remoteConnection) }
            remoteConnection = nil
            isTransportDisconnected = true
        } else {
            disconnect()
            operationError = message
        }
        restoreInput()
    }

    private func restoreInput() {
        if draft.isEmpty, let pendingInput { draft = pendingInput }
        pendingInput = nil
        pendingSendID = nil
    }

    private func isActiveExchange(_ id: UUID?) -> Bool {
        !isClosed && state?.isRunning == true && state?.exchanges.last?.id == id
    }

    private func normalized(_ input: [AgentInput]) -> [AgentInput] {
        input.compactMap { item in
            guard case .text(let text) = item else { return item }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }

    private func recordCommandResult(_ command: AgentSlashCommand, content: [AgentContent], failed: Bool = false) {
        guard !isClosed else { return }
        let status: AgentExecutionStatus = failed ? .failed : .completed
        let result = AgentSlashCommandResult(id: UUID().uuidString, command: command, content: content, status: status)
        var exchange = AgentExchange(input: [.slashCommand(command)])
        exchange.outputs = [.slashCommandResult(result)]
        exchange.status = status
        commandResults.append((state?.exchanges.last?.id, exchange))
        exchanges = merged(exchanges.filter { exchange in !exchange.input.contains { if case .slashCommand = $0 { true } else { false } } })
    }

    private func merged(_ conversation: [AgentExchange]) -> [AgentExchange] {
        var result = commandResults.filter { $0.after == nil }.map(\.exchange)
        for exchange in conversation {
            result.append(exchange)
            result += commandResults.filter { $0.after == exchange.id }.map(\.exchange)
        }
        return result
    }
}
