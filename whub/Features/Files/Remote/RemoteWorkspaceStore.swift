import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class RemoteWorkspaceStore: ObservableObject {
    struct Source: Equatable {
        let hostID: PersistentIdentifier
        let hostName: String
        let projectsPath: String
        let worktreesPath: String
        let sessionID: ObjectIdentifier
    }

    struct Entry: Identifiable, Equatable {
        let id: FileLocation
        let name: String
        let hostName: String
    }

    enum State: Equatable {
        case loading, loaded, failed(String)
    }

    @Published private(set) var states: [PersistentIdentifier: State] = [:]
    @Published private var entries: [PersistentIdentifier: [Entry]] = [:]
    private var sources: [PersistentIdentifier: Source] = [:]
    private var jobs: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var generations: [PersistentIdentifier: UUID] = [:]
    private var refreshID: Int?

    static func connectedSources(hosts: [RemoteHost], connections: RemoteConnectionStore) -> [Source] {
        hosts.compactMap { host in
            guard let session = connections.session(for: host) else { return nil }
            return .init(hostID: host.persistentModelID, hostName: host.name,
                         projectsPath: host.projectsPath, worktreesPath: host.worktreesPath,
                         sessionID: ObjectIdentifier(session))
        }
    }

    func update(hosts: [RemoteHost], connections: RemoteConnectionStore, refreshID: Int) {
        let sessions = Dictionary(uniqueKeysWithValues: hosts.compactMap { host in
            connections.session(for: host).map { (host.persistentModelID, $0) }
        })
        update(sources: Self.connectedSources(hosts: hosts, connections: connections), refreshID: refreshID) { source, root in
            guard let session = sessions[source.hostID], ObjectIdentifier(session) == source.sessionID else {
                throw RemoteSessionError.disconnected
            }
            return try await session.listDirectory(root: root)
        }
    }

    func entries(for current: [Source]) -> [Entry] {
        current.flatMap { source in
            sources[source.hostID] == source ? entries[source.hostID, default: []] : []
        }
    }

    func update(
        sources current: [Source], refreshID: Int,
        list: @escaping @MainActor (Source, String) async throws -> [RemoteFileEntry]
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
                    Entry(id: .remote(hostID: id, path: (source.projectsPath as NSString).appendingPathComponent($0)),
                          name: $0, hostName: source.hostName)
                }
                let worktreeEntries = worktrees.filter { name in
                    projects.contains { project in
                        let prefix = project + "-"
                        guard name.hasPrefix(prefix), let number = Int(name.dropFirst(prefix.count)), number > 0 else { return false }
                        return name == "\(project)-\(number)"
                    }
                }.map {
                    Entry(id: .remote(hostID: id, path: (source.worktreesPath as NSString).appendingPathComponent($0)),
                          name: $0, hostName: source.hostName)
                }
                self.entries[id] = projectEntries + worktreeEntries
                self.states[id] = errors.isEmpty ? .loaded : .failed(errors.joined(separator: "\n"))
                self.jobs.removeValue(forKey: id)
            }
        }
    }

    private static func directoryNames(_ entries: [RemoteFileEntry]) -> [String] {
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
