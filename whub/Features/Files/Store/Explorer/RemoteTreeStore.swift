import Foundation
import SwiftData
import WhubCore

@MainActor
final class RemoteTreeStore {
    struct Source: Equatable {
        let root: FileLocation
        let sessionID: ObjectIdentifier
    }

    enum State: Equatable {
        case loading, loaded, failed(String)
    }

    private(set) var source: Source?
    private(set) var states: [String: State] = [:]
    private(set) var rootItems: [ExplorerItem] = []
    private var items: [FileLocation: ExplorerItem] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var refreshID: Int?
    private var list: (@MainActor (String) async throws -> [RemoteFileEntry])?
    var onChange: (() -> Void)?

    var cachedItems: [ExplorerItem] { Array(items.values) }

    func update(location: FileLocation?, hosts: [RemoteHost], connections: RemoteConnectionStore, refreshID: Int) {
        guard let location,
              case let .remote(hostID, root) = location,
              let host = hosts.first(where: { $0.persistentModelID == hostID }),
              let connection = connections.connection(for: host) else {
            update(source: nil, refreshID: refreshID, list: nil)
            return
        }
        update(source: .init(root: location, sessionID: ObjectIdentifier(connection)), refreshID: refreshID) { path in
            guard connections.connection(for: host) === connection else { throw SSHError.disconnected }
            let session = try await connections.legacySession(for: host)
            let entries = try await session.listDirectory(root: root, path: path)
            guard connections.connection(for: host) === connection else { throw SSHError.disconnected }
            return entries
        }
    }

    func update(source: Source?, refreshID: Int,
                list: (@MainActor (String) async throws -> [RemoteFileEntry])?) {
        guard self.source != source || self.refreshID != refreshID else { return }
        let changed = self.source != source
        let paths = Array(states.keys)
        cancel()
        if changed {
            items.removeAll()
            rootItems = []
        }
        self.source = source
        self.refreshID = refreshID
        self.list = list
        onChange?()
        guard source != nil else { return }
        load(path: "")
        if !changed {
            for path in paths where !path.isEmpty { load(path: path) }
        }
    }

    func children(for item: ExplorerItem?) -> [ExplorerItem] {
        item.map { $0.children ?? [] } ?? rootItems
    }

    func loadChildren(of item: ExplorerItem) {
        guard item.isDirectory, items[item.location] === item, let root = source?.root else { return }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard item.location.path.hasPrefix(prefix),
              root.appending(String(item.location.path.dropFirst(prefix.count))) == item.location else { return }
        load(path: String(item.location.path.dropFirst(prefix.count)))
    }

    private func load(path: String) {
        guard let source, let list, jobs[path] == nil, states[path] != .loaded else { return }
        let generation = generation
        states[path] = .loading
        onChange?()
        jobs[path] = Task { [weak self] in
            do {
                let entries = try await list(path)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                let parent = path.isEmpty ? source.root : source.root.appending(path)
                let previous = path.isEmpty ? self.rootItems : self.items[parent]?.children ?? []
                var seen = Set<String>()
                let children = entries.filter {
                    !$0.name.isEmpty && ![".", "..", ".git", ".DS_Store"].contains($0.name)
                        && !$0.name.contains("/") && !$0.name.contains("\0") && seen.insert($0.name).inserted
                }.map { entry in
                    let location = parent.appending(entry.name)
                    let directory = entry.kind == .directory
                    if let existing = self.items[location], existing.isDirectory == directory { return existing }
                    let item = ExplorerItem(location: location, isDirectory: directory)
                    self.items[location] = item
                    return item
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.location.name.localizedStandardCompare($1.location.name) == .orderedAscending
                }
                let retained = Set(children.map(ObjectIdentifier.init))
                for removed in previous where !retained.contains(ObjectIdentifier(removed)) {
                    let removedPath = path.isEmpty ? removed.location.name : path + "/" + removed.location.name
                    for key in Array(self.states.keys) where key == removedPath || key.hasPrefix(removedPath + "/") {
                        self.jobs.removeValue(forKey: key)?.cancel()
                        self.states.removeValue(forKey: key)
                    }
                    for key in Array(self.items.keys) where key.path.hasPrefix(removed.location.path + "/") {
                        self.items.removeValue(forKey: key)
                    }
                    if self.items[removed.location] === removed { self.items.removeValue(forKey: removed.location) }
                }
                if path.isEmpty { self.rootItems = children }
                else { self.items[parent]?.children = children }
                self.states[path] = .loaded
                self.jobs.removeValue(forKey: path)
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.states[path] = .failed(error.localizedDescription)
                self.jobs.removeValue(forKey: path)
                self.onChange?()
            }
        }
    }

    private func cancel() {
        generation = UUID()
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        states.removeAll()
    }

    func stop() {
        cancel()
        source = nil
        list = nil
        refreshID = nil
        items.removeAll()
        rootItems = []
        onChange?()
    }
}
