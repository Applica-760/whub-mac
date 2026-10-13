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
    private var pendingResumeSourceID: CodexStore.ID?
    private let context: ModelContext
    private let request: ((String, [String: Any], String) async throws -> [String: Any])?

    init(context: ModelContext, request: ((String, [String: Any], String) async throws -> [String: Any])? = nil) {
        self.context = context
        self.request = request
        let session = CodexStore(context: context, request: request)
        sessions = [session]
        selectedSessionID = session.id
        observe(session)
    }

    var selectedSession: CodexStore {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = CodexStore(context: context, request: request)
        observe(session)
        sessions.append(session)
        selectedSessionID = session.id
    }

    @discardableResult
    func resume(_ thread: CodexRecentThread, replacing sourceID: CodexStore.ID) async -> Bool {
        guard !isResuming else { return false }
        resumeError = nil
        guard let source = sessions.first(where: { $0.id == sourceID }) else { return false }
        guard !source.isBusy, !source.isSteering, !source.isResuming, !source.isChangingModel else {
            resumeError = "作業や送信が終わってから会話を再開してください。"
            return false
        }
        if let existing = sessions.first(where: { $0.threadID == thread.id }) {
            return openResumedSession(existing, replacing: sourceID)
        }
        let session = CodexStore(context: context, request: request)
        pendingResume = session
        pendingResumeSourceID = sourceID
        isResuming = true
        defer {
            if pendingResume?.id == session.id {
                pendingResume = nil
                pendingResumeSourceID = nil
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
        return openResumedSession(session, replacing: sourceID)
    }

    @discardableResult
    func openResumedSession(_ session: CodexStore, replacing sourceID: CodexStore.ID) -> Bool {
        guard let threadID = session.threadID, !session.isResuming else { return false }
        guard let sourceIndex = sessions.firstIndex(where: { $0.id == sourceID }),
              !sessions[sourceIndex].isBusy, !sessions[sourceIndex].isSteering,
              !sessions[sourceIndex].isResuming, !sessions[sourceIndex].isChangingModel else {
            if !sessions.contains(where: { $0.id == session.id }) { session.disconnect() }
            if sessions.contains(where: { $0.id == sourceID }) {
                resumeError = "作業や送信が終わってから会話を再開してください。"
            }
            return false
        }
        let existingIndex = sessions.firstIndex(where: { $0.threadID == threadID })
        let target = existingIndex.map { sessions[$0] } ?? session
        if target.id != session.id { session.disconnect() }
        if target.id != sourceID {
            sessions[sourceIndex].disconnect()
            completedSessionIDs.remove(sourceID)
            observe(target)
            var updated = sessions
            updated[sourceIndex] = target
            if let existingIndex { updated.remove(at: existingIndex) }
            sessions = updated
        }
        select(target.id)
        return true
    }

    func select(_ id: CodexStore.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        completedSessionIDs.remove(id)
    }

    func remove(_ id: CodexStore.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if pendingResumeSourceID == id {
            pendingResume?.disconnect()
            pendingResume = nil
            pendingResumeSourceID = nil
            isResuming = false
        }
        sessions[index].disconnect()
        if sessions.count == 1 {
            let replacement = CodexStore(context: context, request: request)
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
        pendingResumeSourceID = nil
        isResuming = false
        for session in sessions { session.disconnect() }
    }
}
