import Foundation
import WhubAgent

/// One tab's memory-only retrieval cache. The remote runtime continues after disconnect.
public actor AgentSessionConnection {
    private struct Content: Sendable {
        let snapshot: AgentSnapshot
        let document: AgentJSONValue
        let images: [UUID: Data]
        let state: AgentSessionState
    }

    private let api: AgentAPI
    public let sessionID: UUID
    private var content: Content?
    private var updating: Task<Content, any Error>?
    private var disconnected = false

    init(api: AgentAPI, sessionID: UUID) {
        self.api = api
        self.sessionID = sessionID
    }

    public func state() throws -> AgentSessionState {
        guard !disconnected, let content else { throw WhubClientError.connectionClosed }
        return content.state
    }

    /// Fetches one complete revision range; 204 returns the cached state unchanged.
    /// The caller owns polling. Failed or cancelled updates never partially change the cache.
    @discardableResult
    public func update() async throws -> AgentSessionState {
        guard !disconnected else { throw WhubClientError.connectionClosed }
        guard updating == nil else { throw WhubClientError.updateInProgress }
        let previous = content
        let task = Task { [api, sessionID] in try await Self.fetch(api, sessionID: sessionID, previous: previous) }
        updating = task
        defer { updating = nil }
        let next = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        guard !disconnected else { throw WhubClientError.connectionClosed }
        do { try Task.checkCancellation() }
        catch {
            if next.snapshot.id != previous?.snapshot.id {
                await Task { [api, sessionID] in
                    try? await api.releaseSnapshot(sessionID: sessionID, snapshotID: next.snapshot.id)
                }.value
            }
            throw error
        }
        content = next
        return next.state
    }

    /// Drops the cache and retrieval data, without calling DELETE /sessions/:id.
    public func disconnect() async throws {
        guard !disconnected else { return }
        disconnected = true
        let snapshot = content?.snapshot
        content = nil
        let task = updating
        task?.cancel()
        if let task, case .success(let result) = await task.result, result.snapshot.id != snapshot?.id {
            try await api.releaseSnapshot(sessionID: sessionID, snapshotID: result.snapshot.id)
        }
        if let snapshot { try await api.releaseSnapshot(sessionID: sessionID, snapshotID: snapshot.id) }
    }

    private static func fetch(_ api: AgentAPI, sessionID: UUID, previous: Content?) async throws -> Content {
        guard let previous else { return try await loadSnapshot(api, sessionID: sessionID, images: [:]) }
        do {
            guard let first = try await api.changes(sessionID: sessionID, snapshotID: previous.snapshot.id,
                                                   after: previous.state.revision) else { return previous }
            let bytes = try await collect(first: first, from: previous.state.revision) { cursor in
                guard let page = try await api.changes(sessionID: sessionID, snapshotID: previous.snapshot.id,
                                                       after: previous.state.revision, cursor: cursor) else {
                    throw WhubClientError.invalidResponse
                }
                return page
            }
            guard first.toRevision > previous.state.revision else { throw WhubClientError.invalidResponse }
            let changes = try api.client.decode([AgentStateChange].self, from: bytes)
            var document = previous.document
            for change in changes { try apply(change, to: &document, path: change.path[...]) }
            return try await materialize(api, sessionID: sessionID, snapshot: previous.snapshot,
                                         document: document, revision: first.toRevision, images: previous.images)
        } catch WhubClientError.api(status: 410, code: "resyncRequired", message: _) {
            try await api.releaseSnapshot(sessionID: sessionID, snapshotID: previous.snapshot.id)
            return try await loadSnapshot(api, sessionID: sessionID, images: previous.images)
        }
    }

    private static func loadSnapshot(_ api: AgentAPI, sessionID: UUID, images: [UUID: Data]) async throws -> Content {
        let snapshot = try await api.openSnapshot(sessionID: sessionID)
        do {
            guard snapshot.byteCount > 0 else { throw WhubClientError.invalidResponse }
            let first = try await api.snapshotPage(sessionID: sessionID, snapshotID: snapshot.id)
            guard first.toRevision == snapshot.revision else { throw WhubClientError.invalidResponse }
            let bytes = try await collect(first: first, from: snapshot.revision, byteCount: snapshot.byteCount) {
                try await api.snapshotPage(sessionID: sessionID, snapshotID: snapshot.id, cursor: $0)
            }
            let document = try api.client.decode(AgentJSONValue.self, from: bytes)
            return try await materialize(api, sessionID: sessionID, snapshot: snapshot, document: document,
                                         revision: snapshot.revision, images: images)
        } catch {
            // Release outside the cancelled task; preserve the original error if cleanup cannot reach the server.
            await Task { try? await api.releaseSnapshot(sessionID: sessionID, snapshotID: snapshot.id) }.value
            throw error
        }
    }

    private static func collect(first: AgentTransferPage, from revision: UInt64, byteCount: Int? = nil,
                                next: (Int) async throws -> AgentTransferPage) async throws -> Data {
        var bytes = Data()
        var page = first
        while true {
            try Task.checkCancellation()
            guard page.fromRevision == revision, page.toRevision == first.toRevision,
                  page.cursor == bytes.count, !page.data.isEmpty, page.data.count <= 512 * 1024 else {
                throw WhubClientError.invalidResponse
            }
            bytes.append(page.data)
            if let byteCount, bytes.count > byteCount { throw WhubClientError.invalidResponse }
            guard let cursor = page.nextCursor else { break }
            guard cursor == bytes.count else { throw WhubClientError.invalidResponse }
            page = try await next(cursor)
        }
        if let byteCount, bytes.count != byteCount { throw WhubClientError.invalidResponse }
        return bytes
    }

    private static func materialize(_ api: AgentAPI, sessionID: UUID, snapshot: AgentSnapshot,
                                    document: AgentJSONValue, revision: UInt64, images: [UUID: Data]) async throws -> Content {
        var references: [UUID: (mediaType: String, byteCount: Int)] = [:]
        try imageReferences(document, into: &references)
        var cache: [UUID: Data] = [:]
        for (id, reference) in references {
            if let data = images[id] {
                guard data.count == reference.byteCount else { throw WhubClientError.invalidResponse }
                cache[id] = data
                continue
            }
            var data = Data()
            while data.count < reference.byteCount {
                let page = try await api.imagePage(sessionID: sessionID, imageID: id, cursor: data.count)
                guard page.id == id, page.mediaType == reference.mediaType, page.byteCount == reference.byteCount,
                      page.cursor == data.count, !page.data.isEmpty, page.data.count <= 512 * 1024 else {
                    throw WhubClientError.invalidResponse
                }
                data.append(page.data)
                guard data.count <= reference.byteCount,
                      page.nextCursor == (data.count < reference.byteCount ? data.count : nil) else {
                    throw WhubClientError.invalidResponse
                }
            }
            cache[id] = data
        }
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        decoder.userInfo[.agentImageData] = cache
        let data = try JSONEncoder().encode(document)
        let state: AgentSessionState
        do { state = try decoder.decode(AgentSessionState.self, from: data) }
        catch { throw WhubClientError.invalidResponse }
        guard state.id == sessionID, state.revision == revision else { throw WhubClientError.invalidResponse }
        return Content(snapshot: snapshot, document: document, images: cache, state: state)
    }

    private static func imageReferences(_ value: AgentJSONValue,
                                        into result: inout [UUID: (mediaType: String, byteCount: Int)]) throws {
        switch value {
        case .object(let values):
            if let size = values["byteCount"], let mediaType = values["mediaType"] {
                guard case .string(let rawID) = values["id"], let id = UUID(uuidString: rawID),
                      case .string(let type) = mediaType, case .number(let count) = size,
                      let byteCount = Int(NSDecimalNumber(decimal: count).stringValue), byteCount > 0 else {
                    throw WhubClientError.invalidResponse
                }
                if let existing = result[id], existing.mediaType != type || existing.byteCount != byteCount {
                    throw WhubClientError.invalidResponse
                }
                result[id] = (type, byteCount)
            }
            for child in values.values { try imageReferences(child, into: &result) }
        case .array(let values):
            for child in values { try imageReferences(child, into: &result) }
        default: break
        }
    }

    private static func apply(_ change: AgentStateChange, to document: inout AgentJSONValue,
                              path: ArraySlice<String>) throws {
        if let key = path.first {
            switch document {
            case .object(var values):
                if path.count == 1 && change.operation == .remove {
                    guard values.removeValue(forKey: key) != nil else { throw WhubClientError.invalidResponse }
                } else {
                    guard path.count == 1 || values[key] != nil else { throw WhubClientError.invalidResponse }
                    var child = values[key] ?? .null
                    try apply(change, to: &child, path: path.dropFirst())
                    values[key] = child
                }
                document = .object(values)
            case .array(var values):
                guard let index = Int(key), String(index) == key, values.indices.contains(index) else {
                    throw WhubClientError.invalidResponse
                }
                try apply(change, to: &values[index], path: path.dropFirst())
                document = .array(values)
            default: throw WhubClientError.invalidResponse
            }
            return
        }
        switch change.operation {
        case .set:
            guard let value = change.value else { throw WhubClientError.invalidResponse }
            document = value
        case .remove: throw WhubClientError.invalidResponse
        case .append:
            switch (document, change.value) {
            case (.array(let old), .array(let new)): document = .array(old + new)
            case (.string(let old), .string(let new)): document = .string(old + new)
            default: throw WhubClientError.invalidResponse
            }
        }
    }
}
