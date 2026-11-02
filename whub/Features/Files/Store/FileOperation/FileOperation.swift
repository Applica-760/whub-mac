import Foundation
import SwiftData
import WhubCore
import WhubClient

@MainActor
enum FileOperation {
    enum OperationError: LocalizedError {
        case invalidName
        case resultUnknown(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "名前には空文字・.・..・/・:・制御文字を使用できません。"
            case let .resultUnknown(message): "操作結果を確認できませんでした。再実行する前にリモートの状態を確認してください。\n\(message)"
            }
        }
    }

    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw OperationError.invalidName }
    }

    private static func destination(in directory: URL, name: String) throws -> URL {
        try validateName(name)
        let url = directory.appendingPathComponent(name)
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            throw CocoaError(.fileWriteFileExists)
        }
        return url
    }

    static func create(in directory: URL, name: String, isDirectory: Bool) throws {
        let url = try destination(in: directory, name: name)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            try Data().write(to: url, options: .withoutOverwriting)
        }
    }

    static func rename(_ url: URL, to name: String) throws {
        try validateName(name)
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: target)
    }

    static func move(_ url: URL, to directory: URL) throws {
        let target = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
    }

    static func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    enum NameOperation { case newFile, newFolder, rename }

    static func commitRemoteName(_ operation: NameOperation, target: FileLocation, name: String,
                                 selectedRoot: FileLocation?, hosts: [WhubCore.Host],
                                 connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let (client, root, path) = try await remoteOperation(target, selectedRoot: selectedRoot, hosts: hosts, connections: connections, servers: servers)
        do {
            switch operation {
            case .rename: try await client.files.rename(root: root, path: path, name: name)
            case .newFile: try await client.files.createFile(root: root, path: path.isEmpty ? name : path + "/" + name)
            case .newFolder: try await client.files.createDirectory(root: root, path: path.isEmpty ? name : path + "/" + name)
            }
        } catch { throw operationError(error) }
    }

    static func trashRemote(_ location: FileLocation, selectedRoot: FileLocation?, hosts: [WhubCore.Host],
                            connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let (client, root, path) = try await remoteOperation(location, selectedRoot: selectedRoot, hosts: hosts, connections: connections, servers: servers)
        do { try await client.files.trash(root: root, path: path) }
        catch { throw operationError(error) }
    }

    static func moveRemote(_ location: FileLocation, to directory: FileLocation, selectedRoot: @autoclosure () -> FileLocation?,
                           hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let (client, root, path) = try await remoteOperation(location, selectedRoot: selectedRoot(), hosts: hosts, connections: connections, servers: servers)
        let (_, destinationRoot, destination) = try await remoteOperation(directory, selectedRoot: selectedRoot(), hosts: hosts, connections: connections, servers: servers)
        guard root == destinationRoot else { throw WhubClientError.invalidPath }
        do { try await client.files.move(root: root, path: path, directory: destination) }
        catch { throw operationError(error) }
    }

    private static func operationError(_ error: Error) -> Error {
        if let clientError = error as? WhubClientError, case .api = clientError { return error }
        return OperationError.resultUnknown(error.localizedDescription)
    }

    private static func remoteOperation(_ location: FileLocation, selectedRoot: FileLocation?, hosts: [WhubCore.Host], connections: RemoteConnectionStore,
                                 servers: RemoteServerStore) async throws -> (WhubClient, String, String) {
        guard case let .remote(hostID, path) = location, case let .remote(rootHost, root) = selectedRoot,
              hostID == rootHost, let host = hosts.compactMap({ $0 as? RemoteHost }).first(where: { $0.persistentModelID == hostID }),
              connections.connection(for: host) != nil else { throw SSHError.disconnected }
        let prefix = root == "/" ? "/" : root + "/"
        guard path == root || path.hasPrefix(prefix) else { throw WhubClientError.invalidPath }
        let client = try await servers.client(for: host)
        return (client, root, path == root ? "" : String(path.dropFirst(prefix.count)))
    }

}
