import Combine
import Foundation

@MainActor
final class RemoteFileStore: ObservableObject {
    enum State {
        case loading
        case loaded(FileStore)
        case failed(String)
        case disconnected
    }

    @Published private(set) var state: State = .loading
    private(set) var document: FileStore?
    private struct Request {
        let connection: (() -> ObjectIdentifier?)?
        let read: () async throws -> String
    }
    private var request: Request?
    private var sessionID: ObjectIdentifier?
    private var job: Task<Void, Never>?
    private var generation = UUID()

    init(location: FileLocation, root: FileLocation?,
         connection: (() -> ObjectIdentifier?)?,
         read: @escaping @MainActor (FileLocation, String, String) async throws -> String) {
        guard case let .remote(hostID, path) = location,
              let root, case let .remote(rootHostID, rootPath) = root, rootHostID == hostID else {
            state = .failed("閲覧ルートが不正です。")
            return
        }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            state = .failed("閲覧ルートの外にあるファイルは取得できません。")
            return
        }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.split(separator: "/").contains(".."),
              !path.contains("\0"), !rootPath.split(separator: "/").contains(".."), rootPath.hasPrefix("/") else {
            state = .failed("閲覧ルートと相対パスが不正です。")
            return
        }
        request = Request(connection: connection, read: { try await read(location, rootPath, relative) })
        refresh()
    }

    func synchronizeConnection() {
        guard let connection = request?.connection else { return }
        if connection() != sessionID { refresh() }
    }

    func refresh() {
        guard let request else { return }
        job?.cancel()
        job = nil
        let generation = UUID()
        self.generation = generation
        let sessionID = request.connection?()
        self.sessionID = sessionID
        if request.connection != nil && sessionID == nil {
            state = .disconnected
            return
        }
        state = .loading
        job = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await request.read()) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            guard request.connection?() == sessionID else {
                self.refresh()
                return
            }
            switch result {
            case let .success(source):
                let document = self.document ?? FileStore(source: source)
                document.updateReadOnly(source: source)
                self.document = document
                state = .loaded(document)
            case let .failure(error):
                state = .failed(error.localizedDescription)
            }
            job = nil
        }
    }

    func close() {
        job?.cancel()
        job = nil
        generation = UUID()
        request = nil
        sessionID = nil
    }
}
