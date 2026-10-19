import Foundation

/// Retrieval-only data. The session remains the source of truth when all views are released.
@MainActor
final class AgentSynchronization {
    private struct View {
        let snapshot: AgentSnapshot
        let data: Data
        var accessedAt: Date
    }
    private struct Revision {
        let from: UInt64
        let to: UInt64
        let data: Data
    }

    static let pageBytes = 512 * 1024
    private static let retainedBytes = 8 * 1024 * 1024
    private static let idleLifetime: TimeInterval = 300
    private var views: [UUID: View] = [:]
    private var revisions: [Revision] = []
    private var previous: AgentJSONValue?
    private var previousRevision: UInt64 = 0
    private var expiry: Task<Void, Never>?

    deinit { expiry?.cancel() }

    func open(_ state: AgentSessionState) throws -> AgentSnapshot {
        let document = try document(state)
        let data = try encoder().encode(document)
        let snapshot = AgentSnapshot(id: UUID(), revision: state.revision, byteCount: data.count)
        if views.isEmpty {
            previous = document
            previousRevision = state.revision
        }
        views[snapshot.id] = View(snapshot: snapshot, data: data, accessedAt: Date())
        scheduleExpiry()
        return snapshot
    }

    func snapshot(_ id: UUID, cursor: Int) throws -> AgentTransferPage {
        let view = try touch(id)
        return try page(view.data, cursor: cursor, from: view.snapshot.revision, to: view.snapshot.revision)
    }

    func changes(_ id: UUID, after: UInt64, cursor: Int) throws -> AgentTransferPage? {
        let view = try touch(id)
        guard after >= view.snapshot.revision, after <= previousRevision else {
            throw AgentError(.invalidInput, "取得IDの範囲内の更新番号を指定してください。")
        }
        if after == previousRevision {
            guard cursor == 0 else { throw invalidCursor() }
            return nil
        }
        guard let revision = revisions.first(where: { $0.from == after }) else { throw expired() }
        return try page(revision.data, cursor: cursor, from: revision.from, to: revision.to)
    }

    func release(_ id: UUID) throws {
        guard views.removeValue(forKey: id) != nil else { throw expired() }
        prune()
        scheduleExpiry()
    }

    func releaseAll() {
        views.removeAll()
        prune()
        expiry?.cancel()
        expiry = nil
    }

    func publish(_ state: AgentSessionState) {
        guard !views.isEmpty, state.revision != previousRevision else { return }
        // These documents contain only our own Codable models; encoding failure is a programming error.
        do {
            let next = try document(state)
            var changes: [AgentStateChange] = []
            if let previous { diff(previous, next, path: [], into: &changes) }
            let data = try encoder().encode(changes)
            revisions.append(Revision(from: previousRevision, to: state.revision, data: data))
            previous = next
            previousRevision = state.revision
            var bytes = revisions.reduce(0) { $0 + $1.data.count }
            while bytes > Self.retainedBytes || revisions.count > 256 {
                bytes -= revisions.removeFirst().data.count
            }
        } catch {
            // A fresh snapshot is required; never fail or stop the underlying agent execution.
            releaseAll()
        }
    }

    private func touch(_ id: UUID) throws -> View {
        guard var view = views[id] else { throw expired() }
        guard Date().timeIntervalSince(view.accessedAt) < Self.idleLifetime else {
            views.removeValue(forKey: id)
            prune()
            scheduleExpiry()
            throw expired()
        }
        view.accessedAt = Date()
        views[id] = view
        return view
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let oldest = views.values.map(\.accessedAt).min() else { expiry = nil; return }
        let delay = max(0, Self.idleLifetime - Date().timeIntervalSince(oldest))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self else { return }
            let now = Date()
            views = views.filter { now.timeIntervalSince($0.value.accessedAt) < Self.idleLifetime }
            prune()
            scheduleExpiry()
        }
    }

    private func prune() {
        if views.isEmpty {
            previous = nil
            revisions.removeAll()
        } else if let oldest = views.values.map(\.snapshot.revision).min() {
            revisions.removeAll { $0.to <= oldest }
        }
    }

    private func page(_ data: Data, cursor: Int, from: UInt64, to: UInt64) throws -> AgentTransferPage {
        guard cursor >= 0, cursor < data.count else { throw invalidCursor() }
        let end = min(data.count, cursor + Self.pageBytes)
        return AgentTransferPage(fromRevision: from, toRevision: to, cursor: cursor,
                                 nextCursor: end < data.count ? end : nil, data: data.subdata(in: cursor..<end))
    }

    private func document(_ state: AgentSessionState) throws -> AgentJSONValue {
        let encoder = encoder()
        encoder.userInfo[.agentImageReferences] = true
        return try JSONDecoder().decode(AgentJSONValue.self, from: encoder.encode(state))
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func diff(_ old: AgentJSONValue, _ new: AgentJSONValue, path: [String], into result: inout [AgentStateChange]) {
        guard old != new else { return }
        switch (old, new) {
        case (.object(let old), .object(let new)):
            for key in old.keys.sorted() where new[key] == nil {
                result.append(.init(operation: .remove, path: path + [key], value: nil))
            }
            for key in new.keys.sorted() {
                if let oldValue = old[key] { diff(oldValue, new[key]!, path: path + [key], into: &result) }
                else { result.append(.init(operation: .set, path: path + [key], value: new[key])) }
            }
        case (.array(let old), .array(let new)) where new.count >= old.count:
            for index in old.indices { diff(old[index], new[index], path: path + [String(index)], into: &result) }
            if new.count > old.count {
                result.append(.init(operation: .append, path: path, value: .array(Array(new.dropFirst(old.count)))))
            }
        case (.string(let old), .string(let new)) where new.hasPrefix(old):
            result.append(.init(operation: .append, path: path, value: .string(String(new.dropFirst(old.count)))))
        default:
            result.append(.init(operation: .set, path: path, value: new))
        }
    }

    private func invalidCursor() -> AgentError { AgentError(.invalidInput, "取得位置が不正です。") }
    private func expired() -> AgentError { AgentError(.resyncRequired, "取得データが解放または期限切れです。スナップショットを再取得してください。") }
}
