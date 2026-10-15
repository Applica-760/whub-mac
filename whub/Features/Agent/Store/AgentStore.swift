import Combine
import Foundation

enum AgentKind {
    case codex
    case claudeCode
}

enum AgentEvent {
    // 同じIDのOutputは、差分ではなく最新の内容全体を渡す。
    case output(AgentOutput)
    case completed
    case failed(String)
}

@MainActor
protocol AgentSession: AnyObject {
    var kind: AgentKind { get }
    // 接続前から購読でき、セッション終了時に閉じる受信口。
    var events: AsyncStream<AgentEvent> { get }

    func connect(directory: String) async throws
    func send(_ input: [AgentInput]) async throws
    func disconnect()
}

@MainActor
final class AgentStore: ObservableObject, Identifiable {
    let id = UUID()
    @Published var draft = ""
    @Published private(set) var outputs: [AgentOutput] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var isBusy = false
    @Published private(set) var isClosed = false
    @Published private(set) var errorMessage: String?

    var agentKind: AgentKind { session.kind }

    var canSend: Bool {
        isConnected && !isClosed && !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let session: any AgentSession
    private var eventTask: Task<Void, Never>?
    private var pendingInput: String?

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

    func send() async {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingInput = text
        draft = ""
        outputs = []
        errorMessage = nil
        isBusy = true

        do {
            try await session.send([.text(text)])
        } catch {
            fail(error.localizedDescription)
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
        guard isBusy else { return }
        switch event {
        case .output(let output):
            if let index = outputs.firstIndex(where: { $0.id == output.id }) {
                outputs[index] = output
            } else {
                outputs.append(output)
            }
        case .completed:
            pendingInput = nil
            isBusy = false
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
        if draft.isEmpty, let pendingInput { draft = pendingInput }
        pendingInput = nil
        isBusy = false
    }
}
