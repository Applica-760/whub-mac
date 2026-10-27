#if os(Linux)
import Foundation
import Glibc
import WhubGit

actor LinuxGitWatchStore {
    enum WatchError: Error {
        case expired, limitReached, failed

        init(_ error: any Error) {
            if let error = error as? LinuxFileWatcher.SystemError,
               error.operation == "inotify_add_watch", error.code == ENOSPC {
                self = .limitReached
            } else {
                self = .failed
            }
        }
    }

    struct Subscription: Encodable {
        let id: UUID
        let revision: UInt64
    }

    private struct Repository {
        var revision: UInt64 = 0
        var subscriptions: [UUID: ContinuousClock.Instant] = [:]
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
        var task: Task<Void, Never>?
        var failure: WatchError?
    }

    private var repositories: [String: Repository] = [:]
    private let lease = Duration.seconds(60)
    private let makeWatcher: @Sendable (Set<URL>, URL, Set<URL>) throws -> LinuxFileWatcher
    private let nextEvent: @Sendable (LinuxFileWatcher) throws -> LinuxFileWatcher.Event?

    init(
        makeWatcher: @escaping @Sendable (Set<URL>, URL, Set<URL>) throws -> LinuxFileWatcher = {
            try LinuxFileWatcher(roots: $0, worktree: $1, managementDirectories: $2)
        },
        nextEvent: @escaping @Sendable (LinuxFileWatcher) throws -> LinuxFileWatcher.Event? = {
            try $0.nextEvent(timeoutMilliseconds: 250)
        }
    ) {
        self.makeWatcher = makeWatcher
        self.nextEvent = nextEvent
    }

    func start(root: String) async throws -> Subscription {
        _ = try FilesService(root: root)
        let url = URL(fileURLWithPath: root).standardizedFileURL
        let directories = try await Git.managementDirectories(at: url)
        let key = url.path
        if repositories[key] == nil {
            let roots = directories.union([url])
            let watcher: LinuxFileWatcher
            do { watcher = try makeWatcher(roots, url, directories) }
            catch { throw WatchError(error) }
            let makeWatcher = makeWatcher
            let nextEvent = nextEvent
            repositories[key] = Repository()
            repositories[key]?.task = Task.detached { [weak self] in
                var watcher = watcher
                while !Task.isCancelled {
                    do {
                        let event = try nextEvent(watcher)
                        guard !Task.isCancelled else { return }
                        if event == .rescan {
                            watcher = try makeWatcher(roots, url, directories)
                        }
                        guard let self, await self.received(key: key, changed: event != nil) else { return }
                    } catch {
                        await self?.fail(key: key, error: WatchError(error))
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, let self,
                                  await self.received(key: key, changed: false) else { return }
                        }
                        return
                    }
                }
            }
        }
        if let failure = repositories[key]?.failure { throw failure }
        let id = UUID()
        repositories[key]?.subscriptions[id] = .now + lease
        return Subscription(id: id, revision: repositories[key]!.revision)
    }

    func wait(id: UUID, after: UInt64, timeout: Duration = .seconds(5)) async throws -> UInt64? {
        let deadline = ContinuousClock.now + timeout
        guard let key = key(for: id), let repository = repositories[key] else { throw WatchError.expired }
        if let failure = repository.failure { throw failure }
        repositories[key]?.subscriptions[id] = .now + lease
        if repository.revision > after { return repository.revision }
        let waiterID = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        repositories[key]?.waiters[waiterID] = continuation
        defer {
            repositories[key]?.waiters.removeValue(forKey: waiterID)
            continuation.finish()
        }
        while true {
            try Task.checkCancellation()
            guard let repository = repositories[key], repository.subscriptions[id] != nil else { throw WatchError.expired }
            if let failure = repository.failure { throw failure }
            if repository.revision > after { return repository.revision }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { return nil }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var iterator = stream.makeAsyncIterator()
                    _ = await iterator.next()
                }
                group.addTask { try await Task.sleep(for: remaining) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
    }

    func stop(id: UUID) throws {
        guard let key = key(for: id) else { throw WatchError.expired }
        repositories[key]?.subscriptions.removeValue(forKey: id)
        notify(key)
        removeIfEmpty(key)
    }

    func shutdown() {
        for repository in repositories.values {
            repository.task?.cancel()
            for waiter in repository.waiters.values { waiter.yield(()) }
        }
        repositories.removeAll()
    }

    private func key(for id: UUID) -> String? {
        repositories.first { $0.value.subscriptions[id] != nil }?.key
    }

    private func received(key: String, changed: Bool) -> Bool {
        guard var repository = repositories[key] else { return false }
        let count = repository.subscriptions.count
        repository.subscriptions = repository.subscriptions.filter { $0.value > .now }
        if changed { repository.revision &+= 1 }
        repositories[key] = repository
        if changed || repository.subscriptions.count != count { notify(key) }
        removeIfEmpty(key)
        return repositories[key] != nil
    }

    private func fail(key: String, error: WatchError) {
        repositories[key]?.failure = error
        notify(key)
    }

    private func notify(_ key: String) {
        guard let repository = repositories[key] else { return }
        for waiter in repository.waiters.values { waiter.yield(()) }
    }

    private func removeIfEmpty(_ key: String) {
        guard let repository = repositories[key], repository.subscriptions.isEmpty else { return }
        repository.task?.cancel()
        repositories.removeValue(forKey: key)
    }
}
#endif
