import Combine
import Foundation
import WhubClient
import WhubCore
import WhubGit

@MainActor
final class RemoteGitStore: ObservableObject {
    let root: FileLocation
    @Published private(set) var changes: [GitAPI.Change] = []
    @Published private(set) var diffs: [String: GitAPI.Diff] = [:]
    @Published private(set) var isConnected = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var watchError: String?

    var fileChanges: [FileLocation: GitChange] {
        changes.reduce(into: [:]) { result, change in
            result[root.appending(change.path)] = change.change == "added" ? .added : change.change == "deleted" ? .deleted : .modified
        }
    }

    private let host: RemoteHost
    private let connections: RemoteConnectionStore
    private let servers: RemoteServerStore
    private let retryInterval: Duration
    private var connectionChanges: AnyCancellable?
    private var listVisible = false
    private var visibleDiffPaths: Set<String> = []
    private var usages: [UUID: (list: Bool, paths: Set<String>)] = [:]
    private var connectionID: ObjectIdentifier?
    private var serverURL: String?
    private var generation = UUID()
    private var requestID = 0
    private var client: WhubClient?
    private var watch: GitWatch?
    private var watchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    init(root: FileLocation, host: RemoteHost, connections: RemoteConnectionStore, servers: RemoteServerStore,
         retryInterval: Duration = .seconds(10)) {
        self.root = root
        self.host = host
        self.connections = connections
        self.servers = servers
        self.retryInterval = retryInterval
        connectionChanges = connections.$states.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.synchronizeConnection() }
    }

    func setUsage(listVisible: Bool, visibleDiffPaths: Set<String>) {
        let changed = self.listVisible != listVisible || self.visibleDiffPaths != visibleDiffPaths
        self.listVisible = listVisible
        self.visibleDiffPaths = visibleDiffPaths
        diffs = diffs.filter { visibleDiffPaths.contains($0.key) }
        guard listVisible || !visibleDiffPaths.isEmpty else {
            disconnect()
            return
        }
        synchronizeConnection()
        if changed { refresh() }
    }

    func setUsage(id: UUID, listVisible: Bool, visibleDiffPaths: Set<String>) {
        if listVisible || !visibleDiffPaths.isEmpty {
            usages[id] = (listVisible, visibleDiffPaths)
        } else {
            usages.removeValue(forKey: id)
        }
        setUsage(listVisible: usages.values.contains { $0.list },
                 visibleDiffPaths: usages.values.reduce(into: Set<String>()) { $0.formUnion($1.paths) })
    }

    func refresh() {
        guard let client else { return }
        requestID += 1
        isLoading = true
        guard loadTask == nil else { return }
        let generation = generation
        loadTask = Task { [weak self] in await self?.load(client: client, generation: generation) }
    }

    private func load(client: WhubClient, generation: UUID) async {
        defer { if self.generation == generation { loadTask = nil } }
        while !Task.isCancelled && self.generation == generation {
            guard let connection = connections.connection(for: host),
                  ObjectIdentifier(connection) == connectionID,
                  servers.configuredURL(for: host) == serverURL else {
                isLoading = false
                return
            }
            let requestID = requestID
            let paths = visibleDiffPaths.sorted()
            let wantsChanges = listVisible
            let rootPath = root.path
            func isCurrent() -> Bool {
                guard !Task.isCancelled, self.generation == generation, self.requestID == requestID,
                      let connection = connections.connection(for: host) else { return false }
                return ObjectIdentifier(connection) == connectionID && servers.configuredURL(for: host) == serverURL
            }
            do {
                let changes = wantsChanges ? try await client.git.changes(root: rootPath) : []
                var diffs: [String: GitAPI.Diff] = [:]
                for path in paths {
                    diffs[path] = try await client.git.diff(root: rootPath, path: path)
                }
                guard isCurrent() else { continue }
                self.changes = changes
                self.diffs = diffs
                errorMessage = nil
            } catch {
                guard isCurrent() else { continue }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            return
        }
    }

    func retry() {
        guard listVisible || !visibleDiffPaths.isEmpty else { return }
        disconnect()
        synchronizeConnection()
    }

    func stop() {
        usages.removeAll()
        listVisible = false
        visibleDiffPaths = []
        connectionChanges = nil
        disconnect()
    }

    private func synchronizeConnection() {
        guard listVisible || !visibleDiffPaths.isEmpty,
              let connection = connections.connection(for: host) else {
            disconnect()
            return
        }
        let id = ObjectIdentifier(connection)
        let url = servers.configuredURL(for: host)
        guard connectionID != id || serverURL != url else { return }
        disconnect()
        connectionID = id
        serverURL = url
        isConnected = true
        isLoading = true
        watchError = nil
        let generation = generation
        let rootPath = root.path
        watchTask = Task { [weak self, host, servers] in
            while !Task.isCancelled {
                do {
                    let client = try await servers.client(for: host)
                    let watch = try await client.git.watch(root: rootPath)
                    guard let self, !Task.isCancelled, self.generation == generation else {
                        await watch.stop()
                        return
                    }
                    self.client = client
                    self.watch = watch
                    self.watchError = nil
                    self.refresh()
                    for try await _ in watch.updates {
                        guard !Task.isCancelled, self.generation == generation else { return }
                        self.refresh()
                    }
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    self.watchError = error.localizedDescription
                    self.requestID += 1
                    self.loadTask?.cancel()
                    self.loadTask = nil
                    self.isLoading = false
                    self.client = nil
                    self.watch = nil
                    if case WhubClientError.api(_, "watch_limit_reached", _) = error {
                        self.watchTask = nil
                        return
                    }
                    do { try await Task.sleep(for: self.retryInterval) } catch { return }
                    guard !Task.isCancelled, self.generation == generation,
                          let connection = self.connections.connection(for: host),
                          ObjectIdentifier(connection) == id,
                          servers.configuredURL(for: host) == url else { return }
                }
            }
        }
    }

    private func disconnect() {
        generation = UUID()
        requestID += 1
        watchTask?.cancel()
        watchTask = nil
        loadTask?.cancel()
        loadTask = nil
        if let watch { Task { await watch.stop() } }
        watch = nil
        client = nil
        connectionID = nil
        serverURL = nil
        isConnected = false
        isLoading = false
        changes = []
        diffs = [:]
    }
}
