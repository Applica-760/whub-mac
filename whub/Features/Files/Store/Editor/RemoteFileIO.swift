import Foundation
import WhubCore
import WhubClient

@MainActor
struct RemoteFileIO {
    let host: RemoteHost?
    let connections: RemoteConnectionStore
    let servers: RemoteServerStore

    var connectionID: ObjectIdentifier? {
        host.flatMap { connections.connection(for: $0) }.map(ObjectIdentifier.init)
    }

    func readText(root: String, path: String) async throws -> String {
        try await perform { try await $0.files.readText(root: root, path: path) }
    }

    func readImage(root: String, path: String) async throws -> Data {
        try await perform { try await $0.files.readImage(root: root, path: path) }
    }

    func writeText(root: String, path: String, expectedText: String, text: String) async throws -> String {
        try await perform {
            try await $0.files.writeText(root: root, path: path, expectedText: expectedText, text: text)
        }
    }

    private func perform<T>(_ operation: (WhubClient) async throws -> T) async throws -> T {
        guard let host, let connection = connections.connection(for: host) else { throw SSHError.disconnected }
        let serverURL = servers.configuredURL(for: host)
        let client = try await servers.client(for: host)
        let result = try await operation(client)
        guard connections.connection(for: host) === connection,
              servers.configuredURL(for: host) == serverURL else { throw SSHError.disconnected }
        return result
    }
}
