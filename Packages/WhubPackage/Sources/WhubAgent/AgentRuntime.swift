import Foundation

/// Own one runtime for the lifetime of the application or server, not per request.
@MainActor
public final class AgentRuntime {
    private let makeAdapter: @MainActor (AgentKind) throws -> any AgentAdapter
    private var sessions: [UUID: AgentSession] = [:]
    private var isShutdown = false

    public init(codexExecutable: String? = nil) {
        makeAdapter = { kind in
            switch kind {
            case .codex: CodexAdapter(client: CodexClient(executable: codexExecutable))
            case .claudeCode: throw AgentError(.unsupported, "Claude Codeの接続は未実装です。")
            }
        }
    }

    init(makeAdapter: @escaping @MainActor (AgentKind) throws -> any AgentAdapter) {
        self.makeAdapter = makeAdapter
    }

    public func create(kind: AgentKind, directory: String) async throws -> AgentSessionState {
        guard !isShutdown else { throw AgentError(.closed, "Runtimeは終了しています。") }
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw AgentError(.invalidInput, "作業ディレクトリには絶対パスを指定してください。")
        }
        let directory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let adapter = try makeAdapter(kind)
        do { try await adapter.connect(directory: directory) }
        catch {
            adapter.close()
            throw AgentError.wrapping(error)
        }
        guard !isShutdown else {
            adapter.close()
            throw AgentError(.closed, "Runtimeは終了しています。")
        }
        // Creating a session belongs to its caller; accepted commands do not.
        if Task.isCancelled {
            adapter.close()
            throw CancellationError()
        }
        let session = AgentSession(directory: directory, adapter: adapter)
        sessions[session.state.id] = session
        return session.state
    }

    public func list() -> [AgentSessionState] {
        sessions.values.map(\.state).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func state(sessionID: UUID) throws -> AgentSessionState {
        try session(sessionID).state
    }

    /// Returns the latest full state, waiting if `revision` is still current.
    /// Cancelling this call removes only that observer, not the session or its execution.
    public func changes(sessionID: UUID, after revision: UInt64) async throws -> AgentSessionState {
        try await session(sessionID).changes(after: revision)
    }

    public func summaries() -> [AgentSessionSummary] { list().map(AgentSessionSummary.init) }

    public func summary(sessionID: UUID) throws -> AgentSessionSummary {
        AgentSessionSummary(try session(sessionID).state)
    }

    public func openSnapshot(sessionID: UUID) throws -> AgentSnapshot {
        let target = try session(sessionID)
        target.synchronization.publish(target.state)
        return try target.synchronization.open(target.state)
    }

    public func snapshotPage(sessionID: UUID, snapshotID: UUID, cursor: Int = 0) throws -> AgentTransferPage {
        try session(sessionID).synchronization.snapshot(snapshotID, cursor: cursor)
    }

    public func changePage(sessionID: UUID, snapshotID: UUID, after revision: UInt64,
                           cursor: Int = 0) throws -> AgentTransferPage? {
        let target = try session(sessionID)
        target.synchronization.publish(target.state)
        return try target.synchronization.changes(snapshotID, after: revision, cursor: cursor)
    }

    /// Releases retrieval data only. Does not close the adapter, interrupt execution, or remove history.
    public func releaseSnapshot(sessionID: UUID, snapshotID: UUID) throws {
        try session(sessionID).synchronization.release(snapshotID)
    }

    public func imagePage(sessionID: UUID, imageID: UUID, cursor: Int = 0) throws -> AgentImagePage {
        let state = try session(sessionID).state
        func inputImage(_ input: AgentInput) -> AgentImageAttachment? {
            if case .image(let image) = input, image.id == imageID { return image }
            return nil
        }
        func contentImage(_ content: AgentContent) -> AgentImageAttachment? {
            if case .image(let image) = content, image.id == imageID { return image }
            return nil
        }
        var found: AgentImageAttachment?
        for exchange in state.exchanges {
            found = exchange.input.lazy.compactMap(inputImage).first
            if found == nil { found = exchange.additionalInputs.lazy.flatMap(\.input).compactMap(inputImage).first }
            if found == nil {
                for output in exchange.outputs {
                    switch output {
                    case .message(let message): found = contentImage(message.content)
                    case .toolUse(let tool):
                        found = tool.arguments.flatMap(contentImage) ?? tool.result?.lazy.compactMap(contentImage).first
                    case .request: break
                    }
                    if found != nil { break }
                }
            }
            if found != nil { break }
        }
        guard let image = found else { throw AgentError(.notFound, "画像が存在しません。") }
        guard cursor >= 0, cursor < image.data.count else { throw AgentError(.invalidInput, "取得位置が不正です。") }
        let end = min(image.data.count, cursor + AgentSynchronization.pageBytes)
        return AgentImagePage(id: image.id, mediaType: image.mediaType, byteCount: image.data.count,
                              cursor: cursor, nextCursor: end < image.data.count ? end : nil,
                              data: image.data.subdata(in: cursor..<end))
    }

    /// Acceptance is distinct from command completion and from turn completion.
    /// Reusing an ID with the same command returns its current receipt within this session's lifetime.
    public func execute(sessionID: UUID, command: AgentCommand) throws -> AgentCommandReceipt {
        let target = try session(sessionID)
        if case .resume(let entry) = command.action,
           let existing = sessions.values.first(where: {
               $0.state.id != sessionID && !$0.state.isClosed && $0.state.kind == target.state.kind
                   && $0.state.conversationID == entry.id
           }) {
            throw AgentError(.conflict, "この会話はセッション\(existing.state.id)で開いています。")
        }
        return try target.execute(command)
    }

    public func models(sessionID: UUID) async throws -> [AgentModelOption] {
        try await session(sessionID).models()
    }

    public func skills(sessionID: UUID) async throws -> [AgentSkill] {
        try await session(sessionID).skills()
    }

    public func status(sessionID: UUID) async throws -> [AgentContent] {
        try await session(sessionID).status()
    }

    public func history(sessionID: UUID, cursor: String? = nil) async throws -> AgentHistoryPage {
        try await session(sessionID).history(cursor: cursor)
    }

    /// Explicitly releases the session and stops its adapter. Transport disconnection must not call this.
    public func close(sessionID: UUID) throws {
        let target = try session(sessionID)
        target.close()
        sessions.removeValue(forKey: sessionID)
    }

    public func shutdown() {
        isShutdown = true
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }

    private func session(_ id: UUID) throws -> AgentSession {
        guard let session = sessions[id] else { throw AgentError(.notFound, "セッションが存在しません。") }
        return session
    }
}
