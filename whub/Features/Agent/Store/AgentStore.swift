import Combine
import Foundation

enum AgentKind {
    case codex
    case claudeCode
}

enum AgentEvent {
    case modelOptionChanged(AgentModelOption)
    // 同じIDのOutputは、差分ではなく最新の内容全体を渡す。
    case output(AgentOutput)
    case completed
    case interrupted
    case failed(String)
}

@MainActor
protocol AgentSession: AnyObject {
    var kind: AgentKind { get }
    // 接続前から購読でき、セッション終了時に閉じる受信口。
    var events: AsyncStream<AgentEvent> { get }

    func connect(directory: String) async throws
    func send(_ input: [AgentInput]) async throws
    func sendAdditionalInput(_ input: [AgentInput]) async throws
    func interrupt() async throws
    func loadModelOptions() async throws -> [AgentModelOption]
    func loadSkills() async throws -> [AgentSkill]
    func loadStatus() async throws -> [AgentContent]
    func changeModel(_ option: AgentModelOption) async throws
    func respond(to requestID: String, with response: AgentResponse) async throws
    func loadHistory(cursor: String?) async throws -> AgentHistoryPage
    func resume(_ entry: AgentHistoryEntry) async throws -> AgentHistorySnapshot
    func disconnect()
}

@MainActor
final class AgentStore: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft: [AgentInput] = []
    @Published private(set) var exchanges: [AgentExchange] = []
    @Published private(set) var historyEntry: AgentHistoryEntry?
    @Published private(set) var isResuming = false
    @Published private(set) var modelOptions: [AgentModelOption] = []
    @Published private(set) var isLoadingModelOptions = false
    @Published private(set) var statusContent: [AgentContent] = []
    @Published private(set) var isLoadingStatus = false
    @Published private(set) var selectedModelOption: AgentModelOption?
    @Published private(set) var isChangingModel = false
    @Published private(set) var respondingRequestIDs: Set<String> = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var isStopping = false
    @Published private(set) var isSendingAdditionalInput = false
    @Published private(set) var isClosed = false
    @Published private(set) var errorMessage: String?

    var agentKind: AgentKind { session.kind }

    var canSend: Bool {
        isConnected && !isBusy && !isChangingModel && !isResuming
    }

    private let session: any AgentSession
    private var eventTask: Task<Void, Never>?
    private var pendingInput: [AgentInput]?

    private var activeExchangeIndex: Int? {
        exchanges.lastIndex { $0.status == .running }
    }

    private func isActiveExchange(_ id: UUID) -> Bool {
        guard !isClosed, let index = activeExchangeIndex else { return false }
        return exchanges[index].id == id
    }

    private func normalizedInput(_ input: [AgentInput]) -> [AgentInput] {
        input.compactMap { item in
            guard case .text(let text) = item else { return item }
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.isEmpty ? nil : .text(trimmedText)
        }
    }

    init(session: any AgentSession) {
        self.session = session
        let events = session.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
            guard !Task.isCancelled else { return }
            self?.streamEnded()
        }
    }

    deinit {
        eventTask?.cancel()
    }

    func connect(directory: String) async {
        guard !isClosed, !isConnecting, !isConnected else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            try await session.connect(directory: directory)
            guard !isClosed else {
                session.disconnect()
                return
            }
            isConnected = true
        } catch {
            guard !isClosed else { return }
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func resume(_ entry: AgentHistoryEntry) async -> Bool {
        guard !isClosed, !isConnected, !isConnecting, !isResuming,
              historyEntry == nil, exchanges.isEmpty else { return false }
        isResuming = true
        errorMessage = nil
        defer { isResuming = false }

        await connect(directory: entry.directory)
        guard isConnected else { return false }

        do {
            let snapshot = try await session.resume(entry)
            guard !isClosed else { return false }
            guard snapshot.entry.id == entry.id,
                  snapshot.exchanges.allSatisfy({ $0.status != .running }) else {
                errorMessage = "指定した会話の完了済みの履歴を確認できませんでした。"
                disconnect()
                return false
            }
            historyEntry = snapshot.entry
            exchanges = snapshot.exchanges
            selectedModelOption = snapshot.selectedModelOption
            return true
        } catch {
            guard !isClosed else { return false }
            errorMessage = error.localizedDescription
            disconnect()
            return false
        }
    }

    func send(_ input: [AgentInput]) async {
        guard canSend else { return }
        let submittedInput = normalizedInput(input)
        guard !submittedInput.isEmpty else { return }
        pendingInput = submittedInput
        draft = []
        exchanges.append(AgentExchange(input: submittedInput))
        errorMessage = nil
        isBusy = true

        do {
            try await session.send(submittedInput)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func sendAdditionalInput(_ input: [AgentInput]) async {
        guard isConnected, isBusy, !isStopping, !isSendingAdditionalInput,
              let index = activeExchangeIndex else { return }
        let submittedInput = normalizedInput(input)
        guard !submittedInput.isEmpty else { return }
        let exchangeID = exchanges[index].id
        isSendingAdditionalInput = true
        errorMessage = nil
        defer { isSendingAdditionalInput = false }

        do {
            try await session.sendAdditionalInput(submittedInput)
            guard let index = exchanges.firstIndex(where: { $0.id == exchangeID }) else { return }
            exchanges[index].input.append(contentsOf: submittedInput)
        } catch {
            guard isActiveExchange(exchangeID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        guard isConnected, isBusy, !isStopping,
              let index = activeExchangeIndex else { return }
        let exchangeID = exchanges[index].id
        isStopping = true
        errorMessage = nil

        do {
            try await session.interrupt()
        } catch {
            guard isActiveExchange(exchangeID) else { return }
            isStopping = false
            errorMessage = error.localizedDescription
        }
    }

    func loadModelOptions() async {
        guard isConnected, !isResuming, !isLoadingModelOptions else { return }
        isLoadingModelOptions = true
        errorMessage = nil
        defer { isLoadingModelOptions = false }

        do {
            let options = try await session.loadModelOptions()
            guard !isClosed else { return }
            modelOptions = options
        } catch {
            guard !isClosed else { return }
            errorMessage = error.localizedDescription
        }
    }

    func loadStatus() async {
        guard isConnected, !isResuming, !isLoadingStatus else { return }
        isLoadingStatus = true
        errorMessage = nil
        defer { isLoadingStatus = false }

        do {
            let content = try await session.loadStatus()
            guard !isClosed else { return }
            statusContent = content
        } catch {
            guard !isClosed else { return }
            errorMessage = error.localizedDescription
        }
    }

    func changeModel(_ option: AgentModelOption) async {
        guard isConnected, !isBusy, !isChangingModel, !isResuming else { return }
        isChangingModel = true
        errorMessage = nil
        defer { isChangingModel = false }

        do {
            try await session.changeModel(option)
        } catch {
            guard !isClosed else { return }
            errorMessage = error.localizedDescription
        }
    }

    func respond(to requestID: String, with response: AgentResponse) async {
        guard isConnected, !respondingRequestIDs.contains(requestID),
              let index = activeExchangeIndex,
              let request = exchanges[index].pendingRequests.first(where: { $0.id == requestID }) else { return }
        switch (request.kind, response) {
        case (.approval, .approval):
            break
        case (.questions(let questions), .answers(let answers)):
            guard questions.allSatisfy({ question in
                guard let answer = answers[question.id] else { return false }
                return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                errorMessage = "すべての質問に回答してください。"
                return
            }
        default:
            errorMessage = "要求に対応する種類の回答を指定してください。"
            return
        }
        let exchangeID = exchanges[index].id
        respondingRequestIDs.insert(requestID)
        errorMessage = nil

        do {
            try await session.respond(to: requestID, with: response)
        } catch {
            guard isActiveExchange(exchangeID) else { return }
            respondingRequestIDs.remove(requestID)
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        guard !isClosed else { return }
        isClosed = true
        isConnected = false
        isConnecting = false
        eventTask?.cancel()
        session.disconnect()
        if isBusy { fail("接続を終了しました。") }
    }

    private func handle(_ event: AgentEvent) {
        if case .modelOptionChanged(let option) = event {
            guard !isResuming else { return }
            selectedModelOption = option
            return
        }
        guard isBusy, let exchangeIndex = activeExchangeIndex else { return }
        switch event {
        case .modelOptionChanged:
            break
        case .output(let output):
            if case .request(let request) = output, request.outcome != nil {
                respondingRequestIDs.remove(request.id)
            }
            if let index = exchanges[exchangeIndex].outputs.firstIndex(where: { $0.id == output.id }) {
                exchanges[exchangeIndex].outputs[index] = output
            } else {
                exchanges[exchangeIndex].outputs.append(output)
            }
        case .completed:
            exchanges[exchangeIndex].status = .completed
            respondingRequestIDs.removeAll()
            pendingInput = nil
            isBusy = false
            isStopping = false
        case .interrupted:
            exchanges[exchangeIndex].status = .interrupted
            respondingRequestIDs.removeAll()
            if draft.isEmpty, let pendingInput { draft = pendingInput }
            pendingInput = nil
            isBusy = false
            isStopping = false
        case .failed(let message):
            fail(message)
        }
    }

    private func streamEnded() {
        isClosed = true
        isConnected = false
        isConnecting = false
        if isBusy { fail("エージェントとの接続が終了しました。") }
    }

    private func fail(_ message: String) {
        errorMessage = message
        respondingRequestIDs.removeAll()
        if let index = activeExchangeIndex { exchanges[index].status = .failed }
        if draft.isEmpty, let pendingInput { draft = pendingInput }
        pendingInput = nil
        isBusy = false
        isStopping = false
    }
}
