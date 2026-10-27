import Foundation

public struct GitAPI: Sendable {
    public struct Change: Decodable, Sendable, Equatable {
        public let path: String
        public let change: String
    }

    public struct Diff: Decodable, Sendable, Equatable {
        public struct Content: Decodable, Sendable, Equatable {
            public let type: String
            public let before: String?
            public let after: String?
            public let reason: String?
        }

        public let path: String
        public let change: String?
        public let content: Content
    }

    struct Subscription: Decodable, Sendable {
        let id: UUID
        let revision: UInt64
    }

    let client: WhubClient

    public func changes(root: String) async throws -> [Change] {
        let data = try await client.request("git/changes", query: query(root: root))
        return try client.decode([Change].self, from: data)
    }

    public func diff(root: String, path: String) async throws -> Diff {
        let data = try await client.request("git/diff", query: query(root: root, path: path))
        return try client.decode(Diff.self, from: data)
    }

    /// Starts monitoring and delivers revisions until stopped or an error occurs.
    public func watch(root: String) async throws -> GitWatch {
        let data = try await client.request("git/watches", method: "POST", query: query(root: root))
        let subscription = try client.decode(Subscription.self, from: data)
        return GitWatch(api: self, subscription: subscription)
    }

    fileprivate func wait(id: UUID, after revision: UInt64) async throws -> UInt64? {
        struct Update: Decodable { let revision: UInt64 }
        let response = try await client.response("git/watches/\(id.uuidString)",
                                                 query: [URLQueryItem(name: "after", value: String(revision))],
                                                 expectedStatuses: [200, 204])
        guard response.status != 204 else { return nil }
        let next = try client.decode(Update.self, from: response.data).revision
        guard next > revision else { throw WhubClientError.invalidResponse }
        return next
    }

    fileprivate func stop(id: UUID) async throws {
        _ = try await client.request("git/watches/\(id.uuidString)", method: "DELETE", expectedStatus: 204)
    }

    private func query(root: String, path: String? = nil) throws -> [URLQueryItem] {
        guard root.hasPrefix("/"), !root.contains("\0"), !root.split(separator: "/").contains("..") else {
            throw WhubClientError.invalidPath
        }
        var items = [URLQueryItem(name: "root", value: root)]
        if let path {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !path.split(separator: "/").contains(".."),
                  path.split(separator: "/").contains(where: { $0 != "." }) else { throw WhubClientError.invalidPath }
            items.append(URLQueryItem(name: "path", value: path))
        }
        return items
    }
}

public final class GitWatch: Sendable {
    public let initialRevision: UInt64
    public let updates: AsyncThrowingStream<UInt64, any Error>
    private let task: Task<Void, Never>

    fileprivate init(api: GitAPI, subscription: GitAPI.Subscription) {
        initialRevision = subscription.revision
        let (updates, continuation) = AsyncThrowingStream<UInt64, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.updates = updates
        let task = Task {
            var revision = subscription.revision
            do {
                while !Task.isCancelled {
                    if let next = try await api.wait(id: subscription.id, after: revision) {
                        revision = next
                        continuation.yield(next)
                    }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish() }
                else { continuation.finish(throwing: error) }
            }
            await Task { try? await api.stop(id: subscription.id) }.value
        }
        self.task = task
        continuation.onTermination = { _ in task.cancel() }
    }

    public func stop() async {
        task.cancel()
        await task.value
    }
}
