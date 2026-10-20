import Combine
import Foundation
import SwiftData
import WhubCore
import WhubClient

@MainActor
final class RemoteWorkspaceStore: ObservableObject {
    struct Source: Equatable {
        let hostID: PersistentIdentifier
        let hostName: String
        let projectsPath: String
        let worktreesPath: String
        let sessionID: ObjectIdentifier
        var serverURL: String? = nil
        var projectNames: [String] = []

        var baseLocation: FileLocation {
            .remote(hostID: hostID, path: (projectsPath as NSString).deletingLastPathComponent)
        }

        // Display-name changes do not invalidate directory listings.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.hostID == rhs.hostID && lhs.projectsPath == rhs.projectsPath
                && lhs.worktreesPath == rhs.worktreesPath && lhs.sessionID == rhs.sessionID
                && lhs.serverURL == rhs.serverURL && lhs.projectNames == rhs.projectNames
        }
    }

    enum State: Equatable {
        case loading, loaded, failed(String)
    }

    @Published private(set) var states: [PersistentIdentifier: State] = [:]
    @Published private var entries: [PersistentIdentifier: [FileLocation]] = [:]
    private var sources: [PersistentIdentifier: Source] = [:]
    private var jobs: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var generations: [PersistentIdentifier: UUID] = [:]
    private var refreshID: Int?

    static func connectedSources(hosts: [RemoteHost], projects: [Project], connections: RemoteConnectionStore) -> [Source] {
        hosts.compactMap { host in
            guard let connection = connections.connection(for: host) else { return nil }
            return .init(hostID: host.persistentModelID, hostName: host.name,
                         projectsPath: host.projectsPath, worktreesPath: host.worktreesPath,
                         sessionID: ObjectIdentifier(connection),
                         serverURL: RemoteServerStore.currentEnvironment == .dev ? host.devServerURL : host.prodServerURL,
                         projectNames: projects.filter {
                             $0.host.persistentModelID == host.persistentModelID && $0.isVisibleInExplorer
                         }.map(\.name))
        }
    }

    func update(hosts: [RemoteHost], connections: RemoteConnectionStore, servers: RemoteServerStore, refreshID: Int, context: ModelContext, projects: [Project]) {
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.persistentModelID, $0) })
        update(sources: Self.connectedSources(hosts: hosts, projects: projects, connections: connections), refreshID: refreshID, context: context) { source, root in
            guard let host = hostsByID[source.hostID],
                  let connection = connections.connection(for: host), ObjectIdentifier(connection) == source.sessionID else {
                throw SSHError.disconnected
            }
            let serverURL = servers.configuredURL(for: host)
            let client = try await servers.client(for: host)
            let entries = try await client.files.listDirectory(root: root)
            guard connections.connection(for: host) === connection, servers.configuredURL(for: host) == serverURL else { throw SSHError.disconnected }
            return entries
        }
    }

    func entries(for current: [Source]) -> [FileLocation] {
        current.flatMap { source in
            sources[source.hostID] == source ? [source.baseLocation] + entries[source.hostID, default: []] : []
        }
    }

    func update(
        sources current: [Source], refreshID: Int, context: ModelContext,
        list: @escaping @MainActor (Source, String) async throws -> [FilesAPI.FileEntry]
    ) {
        let ids = Set(current.map(\.hostID))
        for id in Array(sources.keys) where !ids.contains(id) {
            jobs.removeValue(forKey: id)?.cancel()
            generations.removeValue(forKey: id)
            sources.removeValue(forKey: id)
            entries.removeValue(forKey: id)
            states.removeValue(forKey: id)
        }
        let refresh = self.refreshID != refreshID
        self.refreshID = refreshID
        for source in current {
            let id = source.hostID
            guard refresh || sources[id] != source else { continue }
            jobs[id]?.cancel()
            if sources[id] != source { entries.removeValue(forKey: id) }
            sources[id] = source
            let generation = UUID()
            generations[id] = generation
            states[id] = .loading
            jobs[id] = Task { [weak self] in
                var errors: [String] = []
                do {
                    guard let host = context.model(for: id) as? RemoteHost else { throw SSHError.disconnected }
                    let workspace = try await ProjectStore(context: context).resolveWorkspace(for: host) { path in
                        try Task.checkCancellation()
                        do { return Self.directoryNames(try await list(source, path)) }
                        catch {
                            errors.append("\(path): \(error.localizedDescription)")
                            return []
                        }
                    }
                    guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                    self.entries[id] = workspace.projects.map { .remote(hostID: id, path: $0.path) }
                        + workspace.worktrees.map { .remote(hostID: id, path: $0.path) }
                    self.states[id] = errors.isEmpty ? .loaded : .failed(errors.joined(separator: "\n"))
                } catch {
                    guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                    self.entries[id] = []
                    self.states[id] = .failed(error.localizedDescription)
                }
                guard let self, self.generations[id] == generation else { return }
                self.jobs.removeValue(forKey: id)
            }
        }
    }

    private static func directoryNames(_ entries: [FilesAPI.FileEntry]) -> [String] {
        entries.filter { $0.kind == .directory }.map(\.name)
    }

    func stop() {
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        generations.removeAll()
        sources.removeAll()
        entries.removeAll()
        states.removeAll()
    }
}
