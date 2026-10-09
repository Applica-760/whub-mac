import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class RemoteViewerStore: ObservableObject {
    enum State {
        case loading
        case loaded(FileStore)
        case failed(String)
        case disconnected
    }

    @Published private(set) var states: [FileLocation: State] = [:]
    private struct Request {
        let connection: (() -> ObjectIdentifier?)?
        let read: () async throws -> String
    }
    private var requests: [FileLocation: Request] = [:]
    private var files: [FileLocation: FileStore] = [:]
    private var sessionIDs: [FileLocation: ObjectIdentifier] = [:]
    private var connectionChanges: AnyCancellable?
    private weak var connections: RemoteConnectionStore?
    private var jobs: [FileLocation: Task<Void, Never>] = [:]
    private var generations: [FileLocation: UUID] = [:]

    func file(for location: FileLocation) -> FileStore? {
        files[location]
    }

    func load(_ location: FileLocation, root: FileLocation?, hosts: [RemoteHost], connections: RemoteConnectionStore) {
        if self.connections !== connections {
            self.connections = connections
            connectionChanges = connections.$states.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.synchronizeConnections() }
        }
        guard case let .remote(hostID, _) = location else { return }
        let host = hosts.first { $0.persistentModelID == hostID }
        load(location, root: root, connection: {
            host.flatMap { connections.session(for: $0) }.map(ObjectIdentifier.init)
        }) { _, rootPath, path in
            guard let host, let session = connections.session(for: host) else {
                throw RemoteSessionError.disconnected
            }
            let text = try await session.readText(root: rootPath, path: path)
            guard connections.session(for: host) === session else { throw RemoteSessionError.disconnected }
            return text
        }
    }

    func load(_ location: FileLocation, root: FileLocation?,
              connection: (() -> ObjectIdentifier?)? = nil,
              read: @escaping @MainActor (FileLocation, String, String) async throws -> String) {
        guard case let .remote(hostID, path) = location, states[location] == nil else { return }
        guard let root, case let .remote(rootHostID, rootPath) = root, rootHostID == hostID else {
            states[location] = .failed("閲覧ルートが不正です。")
            return
        }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            states[location] = .failed("閲覧ルートの外にあるファイルは取得できません。")
            return
        }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".."),
              !path.contains("\0"), !rootPath.split(separator: "/").contains(".."), rootPath.hasPrefix("/") else {
            states[location] = .failed("閲覧ルートと相対パスが不正です。")
            return
        }
        requests[location] = Request(connection: connection, read: { try await read(location, rootPath, relative) })
        start(location)
    }

    func refresh() {
        for location in Array(requests.keys) { start(location) }
    }

    func synchronizeConnections() {
        for (location, request) in requests {
            guard let connection = request.connection else { continue }
            let current = connection()
            if current != sessionIDs[location] { start(location) }
        }
    }

    private func start(_ location: FileLocation) {
        guard let request = requests[location] else { return }
        jobs.removeValue(forKey: location)?.cancel()
        let generation = UUID()
        generations[location] = generation
        let sessionID = request.connection?()
        sessionIDs[location] = sessionID
        if request.connection != nil && sessionID == nil {
            states[location] = .disconnected
            return
        }
        states[location] = .loading
        jobs[location] = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await request.read()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.generations[location] == generation else { return }
            guard request.connection?() == sessionID else {
                self.start(location)
                return
            }
            switch result {
            case let .success(source):
                let file = self.files[location] ?? FileStore(source: source)
                file.updateReadOnly(source: source)
                self.files[location] = file
                self.states[location] = .loaded(file)
            case let .failure(error):
                self.states[location] = .failed(error.localizedDescription)
            }
            self.jobs.removeValue(forKey: location)
        }
    }

    func close(_ location: FileLocation) {
        jobs.removeValue(forKey: location)?.cancel()
        generations.removeValue(forKey: location)
        requests.removeValue(forKey: location)
        sessionIDs.removeValue(forKey: location)
        files.removeValue(forKey: location)
        states.removeValue(forKey: location)
        if requests.isEmpty {
            connectionChanges = nil
            connections = nil
        }
    }
}
