import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class RemoteFileViewerStore: ObservableObject {
    enum State {
        case loading
        case loaded(FileStore)
        case failed(String)
    }

    @Published private(set) var states: [FileLocation: State] = [:]
    private var jobs: [FileLocation: Task<Void, Never>] = [:]
    private var generations: [FileLocation: UUID] = [:]

    func file(for location: FileLocation) -> FileStore? {
        guard case let .loaded(file) = states[location] else { return nil }
        return file
    }

    func load(_ location: FileLocation, root: FileLocation?, hosts: [RemoteHost], connections: RemoteConnectionStore) {
        load(location, root: root) { hostLocation, rootPath, path in
            guard case let .remote(hostID, _) = hostLocation,
                  let host = hosts.first(where: { $0.persistentModelID == hostID }),
                  let session = connections.session(for: host) else {
                throw RemoteSessionError.disconnected
            }
            let text = try await session.readText(root: rootPath, path: path)
            guard connections.session(for: host) === session else { throw RemoteSessionError.disconnected }
            return text
        }
    }

    func load(_ location: FileLocation, root: FileLocation?,
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
        let generation = UUID()
        generations[location] = generation
        states[location] = .loading
        jobs[location] = Task { [weak self] in
            let result: State
            do { result = .loaded(FileStore(source: try await read(location, rootPath, relative))) }
            catch { result = .failed(error.localizedDescription) }
            guard !Task.isCancelled, let self, self.generations[location] == generation else { return }
            self.states[location] = result
            self.jobs.removeValue(forKey: location)
        }
    }

    func close(_ location: FileLocation) {
        jobs.removeValue(forKey: location)?.cancel()
        generations.removeValue(forKey: location)
        states.removeValue(forKey: location)
    }
}
