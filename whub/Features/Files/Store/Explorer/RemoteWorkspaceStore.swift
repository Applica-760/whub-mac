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

        // Display-name changes do not invalidate directory listings.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.hostID == rhs.hostID && lhs.projectsPath == rhs.projectsPath
                && lhs.worktreesPath == rhs.worktreesPath && lhs.sessionID == rhs.sessionID
                && lhs.serverURL == rhs.serverURL
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

    static func connectedSources(hosts: [RemoteHost], connections: RemoteConnectionStore) -> [Source] {
        hosts.compactMap { host in
            guard let connection = connections.connection(for: host) else { return nil }
            return .init(hostID: host.persistentModelID, hostName: host.name,
                         projectsPath: host.projectsPath, worktreesPath: host.worktreesPath,
                         sessionID: ObjectIdentifier(connection),
                         serverURL: RemoteServerStore.currentEnvironment == .dev ? host.devServerURL : host.prodServerURL)
        }
    }

    func update(hosts: [RemoteHost], connections: RemoteConnectionStore, servers: RemoteServerStore, refreshID: Int) {
        let hostsByID = Dictionary(uniqueKeysWithValues: hosts.map { ($0.persistentModelID, $0) })
        update(sources: Self.connectedSources(hosts: hosts, connections: connections), refreshID: refreshID) { source, root in
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
            sources[source.hostID] == source ? entries[source.hostID, default: []] : []
        }
    }

    func update(
        sources current: [Source], refreshID: Int,
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
                var projects: [String] = []
                var worktrees: [String] = []
                var errors: [String] = []
                do { projects = Self.directoryNames(try await list(source, source.projectsPath)) }
                catch { errors.append("Projects: \(error.localizedDescription)") }
                guard !Task.isCancelled else { return }
                do { worktrees = Self.directoryNames(try await list(source, source.worktreesPath)) }
                catch { errors.append("Worktrees: \(error.localizedDescription)") }
                guard !Task.isCancelled, let self, self.generations[id] == generation else { return }
                let projectEntries = projects.map {
                    FileLocation.remote(hostID: id, path: (source.projectsPath as NSString).appendingPathComponent($0))
                }
                let worktreeEntries = worktrees.filter { name in
                    projects.contains { project in
                        let prefix = project + "-"
                        guard name.hasPrefix(prefix), let number = Int(name.dropFirst(prefix.count)), number > 0 else { return false }
                        return name == "\(project)-\(number)"
                    }
                }.map {
                    FileLocation.remote(hostID: id, path: (source.worktreesPath as NSString).appendingPathComponent($0))
                }
                self.entries[id] = projectEntries + worktreeEntries
                self.states[id] = errors.isEmpty ? .loaded : .failed(errors.joined(separator: "\n"))
                self.jobs.removeValue(forKey: id)
            }
        }
    }

    private static func directoryNames(_ entries: [FilesAPI.FileEntry]) -> [String] {
        entries.filter {
            $0.kind == .directory && !$0.name.isEmpty && $0.name != "." && $0.name != ".."
                && !$0.name.contains("/") && !$0.name.contains("\0")
        }.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
