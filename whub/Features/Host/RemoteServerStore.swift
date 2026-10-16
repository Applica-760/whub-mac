import Combine
import Foundation
import SwiftData
import WhubClient
import WhubCore

enum RemoteServerError: LocalizedError {
    case missingURL, invalidURL

    var errorDescription: String? {
        switch self {
        case .missingURL: "Server URL is not configured for this environment."
        case .invalidURL: "Server URL must use HTTP with a valid host and port, without credentials, a query or a fragment."
        }
    }
}

@MainActor
final class RemoteServerStore: ObservableObject {
    #if DEBUG
    static let currentEnvironment: Environment = .dev
    #else
    static let currentEnvironment: Environment = .prod
    #endif

    func configuredURL(for host: RemoteHost) -> String? {
        Self.currentEnvironment == .dev ? host.devServerURL : host.prodServerURL
    }
    enum Environment: Hashable { case dev, prod }

    private struct Key: Hashable {
        let hostID: PersistentIdentifier
        let environment: Environment
    }

    private struct Entry {
        let connection: SSHConnectionService
        let remoteURL: URL
        let remoteHost: String
        let remotePort: Int
        let localPort: Int
        let client: WhubClient
    }

    private struct Job {
        let id: UUID
        let connection: SSHConnectionService
        let remoteURL: URL
        let task: Task<Entry, Error>
    }

    private let connections: RemoteConnectionStore
    private let session: URLSession
    private let forward: (SSHConnectionService, String, Int) async throws -> Int
    private let cancel: (SSHConnectionService, Int, String, Int) async throws -> Void
    private var entries: [Key: Entry] = [:]
    private var jobs: [Key: Job] = [:]
    private var changes: AnyCancellable?

    init(
        connections: RemoteConnectionStore,
        session: URLSession = .shared,
        forward: @escaping (SSHConnectionService, String, Int) async throws -> Int = {
            try await $0.forward(remoteHost: $1, remotePort: $2)
        },
        cancel: @escaping (SSHConnectionService, Int, String, Int) async throws -> Void = {
            try await $0.cancelForward(localPort: $1, remoteHost: $2, remotePort: $3)
        }
    ) {
        self.connections = connections
        self.session = session
        self.forward = forward
        self.cancel = cancel
        changes = connections.$states.sink { [weak self] states in
            guard let self else { return }
            // Published emits before the store's states property changes.
            for key in Set(self.entries.keys).union(self.jobs.keys) where states[key.hostID] != .connected {
                self.discard(key)
            }
        }
    }

    func client(for host: RemoteHost) async throws -> WhubClient {
        try await client(for: host, environment: Self.currentEnvironment)
    }

    func client(for host: RemoteHost, environment: Environment) async throws -> WhubClient {
        try Task.checkCancellation()
        guard let connection = connections.connection(for: host) else { throw SSHError.disconnected }
        let remoteURL = try serverURL(for: host, environment: environment)
        let key = Key(hostID: host.persistentModelID, environment: environment)
        if let entry = entries[key], entry.connection === connection, entry.remoteURL == remoteURL {
            return entry.client
        }
        if let job = jobs[key], job.connection === connection, job.remoteURL == remoteURL {
            let entry = try await job.task.value
            try Task.checkCancellation()
            guard connections.connection(for: host) === connection else { throw SSHError.disconnected }
            return entry.client
        }
        discard(key)
        let id = UUID()
        let task = Task { [weak self, forward, cancel, session] in
            var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)!
            let remoteHost = components.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let remotePort = components.port ?? 80
            let localPort = try await forward(connection, remoteHost, remotePort)
            do {
                try Task.checkCancellation()
                guard let self, self.jobs[key]?.id == id,
                      self.connections.connection(for: host) === connection,
                      try self.serverURL(for: host, environment: environment) == remoteURL else {
                    throw SSHError.disconnected
                }
                components.host = "127.0.0.1"
                components.port = localPort
                guard let localURL = components.url else { throw RemoteServerError.invalidURL }
                let entry = Entry(connection: connection, remoteURL: remoteURL, remoteHost: remoteHost,
                                  remotePort: remotePort, localPort: localPort,
                                  client: try WhubClient(baseURL: localURL, session: session))
                self.entries[key] = entry
                self.jobs.removeValue(forKey: key)
                return entry
            } catch {
                await Task { try? await cancel(connection, localPort, remoteHost, remotePort) }.value
                throw error
            }
        }
        jobs[key] = Job(id: id, connection: connection, remoteURL: remoteURL, task: task)
        do {
            let entry = try await task.value
            try Task.checkCancellation()
            guard connections.connection(for: host) === connection else { throw SSHError.disconnected }
            return entry.client
        } catch {
            if jobs[key]?.id == id { jobs.removeValue(forKey: key) }
            throw error
        }
    }

    func close() async {
        let tasks = jobs.values.map(\.task)
        let cleanups = Set(entries.keys).union(jobs.keys).compactMap { discard($0) }
        for task in tasks { _ = try? await task.value }
        for cleanup in cleanups { await cleanup.value }
    }

    @discardableResult
    private func discard(_ key: Key) -> Task<Void, Never>? {
        jobs.removeValue(forKey: key)?.task.cancel()
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        return Task { [cancel] in
            try? await cancel(entry.connection, entry.localPort, entry.remoteHost, entry.remotePort)
        }
    }

    private func serverURL(for host: RemoteHost, environment: Environment) throws -> URL {
        guard let rawValue = environment == .dev ? host.devServerURL : host.prodServerURL,
              !rawValue.isEmpty else { throw RemoteServerError.missingURL }
        guard let url = URL(string: rawValue, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http", let hostname = components.host, !hostname.isEmpty,
              (1...65535).contains(components.port ?? 80),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw RemoteServerError.invalidURL }
        return url
    }

    isolated deinit {
        jobs.values.forEach { $0.task.cancel() }
        for entry in entries.values {
            Task { [cancel] in
                try? await cancel(entry.connection, entry.localPort, entry.remoteHost, entry.remotePort)
            }
        }
    }
}
