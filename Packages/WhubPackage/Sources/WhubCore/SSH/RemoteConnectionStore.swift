import Combine
import Foundation
import SwiftData

@MainActor
public final class RemoteConnectionStore: ObservableObject {
    public enum State: Equatable {
        case disconnected, connecting, connected, disconnecting
        case failed(String)
    }

    @Published public private(set) var states: [PersistentIdentifier: State] = [:]
    private var connections: [PersistentIdentifier: SSHConnectionService] = [:]
    let legacySessions = LegacyRemoteSessions()
    private var jobs: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var generations: [PersistentIdentifier: UUID] = [:]
    private var shuttingDown = false
    private let open: @MainActor (RemoteHost) async throws -> SSHConnectionService

    private var hostChanges: AnyCancellable?

    public convenience init() {
        self.init(open: { host in
            try await SSHConnectionService.connect(configuration: SSH.Configuration(
                hostname: host.hostname, user: host.user, port: host.port, identityFile: host.identityFile
            ))
        })
    }

    init(open: @escaping @MainActor (RemoteHost) async throws -> SSHConnectionService) {
        self.open = open
        hostChanges = NotificationCenter.default.publisher(for: HostStore.connectionInvalidated)
            .sink { [weak self] notification in
                // HostStore posts synchronously on MainActor, before changing the model.
                MainActor.assumeIsolated {
                    guard let self, let id = notification.object as? PersistentIdentifier,
                          self.connections[id] != nil || self.jobs[id] != nil else { return }
                    _ = self.beginDisconnect(id)
                }
            }
    }

    public func state(for host: RemoteHost) -> State {
        states[host.persistentModelID] ?? .disconnected
    }

    public func connection(for host: RemoteHost) -> SSHConnectionService? {
        guard state(for: host) == .connected,
              let connection = connections[host.persistentModelID], connection.isConnected else { return nil }
        return connection
    }

    public func connect(_ host: RemoteHost) async {
        let id = host.persistentModelID
        guard !shuttingDown else { return }
        switch state(for: host) {
        case .connecting, .connected, .disconnecting: return
        case .disconnected, .failed: break
        }
        let generation = UUID()
        generations[id] = generation
        states[id] = .connecting
        let previousSession = connections.removeValue(forKey: id)
        previousSession?.onDisconnect = nil
        let task = Task { [weak self, open] in
            do {
                await previousSession?.close()
                if let previousSession { await self?.legacySessions.close(for: previousSession) }
                try Task.checkCancellation()
                let session = try await open(host)
                guard let self, !Task.isCancelled, self.generations[id] == generation else {
                    await session.close()
                    return
                }
                self.connections[id] = session
                self.states[id] = .connected
                session.onDisconnect = { [weak self] error in
                    guard let self, self.generations[id] == generation else { return }
                    self.states[id] = .failed(error.localizedDescription)
                }
            } catch {
                guard let self, self.generations[id] == generation else { return }
                self.states[id] = error is CancellationError ? .disconnected : .failed(error.localizedDescription)
            }
            if self?.generations[id] == generation { self?.jobs.removeValue(forKey: id) }
        }
        jobs[id] = task
        await task.value
    }

    public func disconnect(_ host: RemoteHost) async {
        await beginDisconnect(host.persistentModelID).value
    }

    private func beginDisconnect(_ id: PersistentIdentifier) -> Task<Void, Never> {
        if states[id] == .disconnecting, let task = jobs[id] { return task }
        let generation = UUID()
        generations[id] = generation
        let previous = jobs.removeValue(forKey: id)
        previous?.cancel()
        let session = connections.removeValue(forKey: id)
        session?.onDisconnect = nil
        states[id] = .disconnecting
        let task = Task { [weak self] in
            await session?.close()
            if let session { await self?.legacySessions.close(for: session) }
            // Wait for cancelled attempts too: a late result must be closed before reconnecting.
            await previous?.value
            guard let self, self.generations[id] == generation else { return }
            self.states[id] = .disconnected
            self.jobs.removeValue(forKey: id)
        }
        jobs[id] = task
        return task
    }

    public func shutdown() async {
        shuttingDown = true
        let ids = Set(connections.keys).union(jobs.keys)
        let tasks = ids.map { beginDisconnect($0) }
        for task in tasks { await task.value }
    }
}
