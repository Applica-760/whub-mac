import Combine
import Foundation
import SwiftData
import WhubCore

@MainActor
final class RemoteEditorStore: ObservableObject {
    @Published private(set) var fileStores: [FileLocation: RemoteFileStore] = [:] {
        didSet {
            fileChanges = Publishers.MergeMany(fileStores.values.map(\.objectWillChange))
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    private var fileChanges: AnyCancellable?
    private var connectionChanges: AnyCancellable?
    private weak var connections: RemoteConnectionStore?

    var states: [FileLocation: RemoteFileStore.State] { fileStores.mapValues(\.state) }

    func file(for location: FileLocation) -> EditContentStore? {
        fileStores[location]?.document
    }

    func load(_ location: FileLocation, root: FileLocation?, hosts: [RemoteHost], connections: RemoteConnectionStore, servers: RemoteServerStore) {
        if self.connections !== connections {
            self.connections = connections
            connectionChanges = connections.$states.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.synchronizeConnections() }
        }
        guard case let .remote(hostID, _) = location else { return }
        let host = hosts.first { $0.persistentModelID == hostID }
        let io = RemoteFileIO(host: host, connections: connections, servers: servers)
        load(location, root: root, connection: { io.connectionID },
             write: io.writeText, readImage: io.readImage) { _, rootPath, path in
            try await io.readText(root: rootPath, path: path)
        }
    }

    func load(_ location: FileLocation, root: FileLocation?,
              connection: (() -> ObjectIdentifier?)? = nil,
              write: @escaping @MainActor (String, String, String, String) async throws -> String,
              readImage: (@MainActor (String, String) async throws -> Data)? = nil,
              read: @escaping @MainActor (FileLocation, String, String) async throws -> String) {
        guard case .remote = location, fileStores[location] == nil else { return }
        fileStores[location] = RemoteFileStore(location: location, root: root, connection: connection,
                                               write: write, readImage: readImage, read: read)
    }

    func refresh() {
        for file in fileStores.values { file.refresh() }
    }

    func synchronizeConnections() {
        for file in fileStores.values { file.synchronizeConnection() }
    }

    func close(_ location: FileLocation) {
        fileStores.removeValue(forKey: location)?.close()
        if fileStores.isEmpty {
            connectionChanges = nil
            connections = nil
        }
    }
}
