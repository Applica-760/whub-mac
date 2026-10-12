import AppKit
import Combine
import SwiftData

@MainActor
final class CodexTabsStore: ObservableObject {
    @Published private(set) var sessions: [CodexStore]
    @Published private(set) var selectedSessionID: CodexStore.ID
    @Published private(set) var completedSessionIDs: Set<CodexStore.ID> = []
    @Published private(set) var isResuming = false
    @Published private(set) var resumeError: String?
    private var pendingResume: CodexStore?
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        let session = CodexStore(context: context)
        sessions = [session]
        selectedSessionID = session.id
        observe(session)
    }

    var selectedSession: CodexStore {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = CodexStore(context: context)
        observe(session)
        sessions.append(session)
        selectedSessionID = session.id
    }

    @discardableResult
    func resume(_ thread: CodexRecentThread) async -> Bool {
        guard !isResuming else { return false }
        resumeError = nil
        if let existing = sessions.first(where: { $0.threadID == thread.id }) {
            select(existing.id)
            return true
        }
        let session = CodexStore(context: context)
        pendingResume = session
        isResuming = true
        defer {
            if pendingResume?.id == session.id {
                pendingResume = nil
                isResuming = false
            }
        }
        let succeeded = await session.resume(thread)
        guard pendingResume?.id == session.id else { return false }
        guard succeeded else {
            resumeError = session.errorMessage ?? "会話を再開できませんでした。"
            session.disconnect()
            return false
        }
        return openResumedSession(session)
    }

    @discardableResult
    func openResumedSession(_ session: CodexStore) -> Bool {
        guard let threadID = session.threadID, !session.isResuming else { return false }
        if let existing = sessions.first(where: { $0.threadID == threadID }) {
            if existing.id != session.id { session.disconnect() }
            select(existing.id)
        } else {
            observe(session)
            sessions.append(session)
            select(session.id)
        }
        return true
    }

    func select(_ id: CodexStore.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        completedSessionIDs.remove(id)
    }

    func remove(_ id: CodexStore.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].disconnect()
        if sessions.count == 1 {
            let replacement = CodexStore(context: context)
            observe(replacement)
            sessions[index] = replacement
        } else {
            sessions.remove(at: index)
        }
        completedSessionIDs.remove(id)
        if selectedSessionID == id {
            select(sessions[min(index, sessions.count - 1)].id)
        }
        assert(!sessions.isEmpty && sessions.contains { $0.id == selectedSessionID })
        assert(!sessions.contains { $0.id == id } && !completedSessionIDs.contains(id))
    }

    private func observe(_ session: CodexStore) {
        let id = session.id
        session.onNotification = { [weak self] sound in
            guard let self, self.sessions.contains(where: { $0.id == id }) else { return }
            NSSound(named: sound)?.play()
        }
        session.onCompletionChange = { [weak self] completed in
            guard let self, self.sessions.contains(where: { $0.id == id }) else { return }
            if completed { self.completedSessionIDs.insert(id) }
            else { self.completedSessionIDs.remove(id) }
        }
    }

    func move(_ id: CodexStore.ID, before target: CodexStore.ID?) {
        guard let reordered = reorderedTabs(sessions, moving: id, before: target, identifiedBy: \.id) else { return }
        sessions = reordered
    }

    func disconnect() {
        pendingResume?.disconnect()
        pendingResume = nil
        isResuming = false
        for session in sessions { session.disconnect() }
    }
}
