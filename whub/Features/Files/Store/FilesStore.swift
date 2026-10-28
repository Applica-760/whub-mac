import Combine
import Foundation
import SwiftData
import WhubCore
import WhubGit
import WhubClient

@MainActor
final class FilesStore: ObservableObject {
    let explorer = ExplorerStore()
    @Published private(set) var activeEditor = EditorStore()
    private var editorsByWorkspace: [FileLocation?: EditorStore] = [:]
    private var workspaceChanges: AnyCancellable?
    let git = GitStore()
    private(set) var remoteGitStores: [FileLocation: RemoteGitStore] = [:]
    @Published private(set) var refreshID = 0
    private var rootChanges: AnyCancellable?
    private var isCommittingRemoteName = false
    private var remoteFileOperation: FileLocation?

    init() {
        editorsByWorkspace[nil] = activeEditor
        workspaceChanges = explorer.$selectedLocation.removeDuplicates().sink { [weak self] workspace in
            guard let self else { return }
            if let editor = editorsByWorkspace[workspace] {
                activeEditor = editor
            } else {
                let editor = EditorStore()
                editorsByWorkspace[workspace] = editor
                activeEditor = editor
            }
        }
        rootChanges = explorer.localTree.$rootURL.removeDuplicates().sink { [weak self] root in
            guard let self else { return }
            git.setRoot(root)
            git.refresh()
        }
        git.onManagementDirectoriesChange = { [weak self] in
            guard let self else { return }
            explorer.localTree.managementDirectories = git.managementDirectories
        }
        explorer.localTree.onChanges = { [weak self] event, treeChanged in
            guard let self, let root = explorer.rootURL else { return }
            guard case let .changed(paths) = event else { git.refresh(); return }
            let roots = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
            if treeChanged || Git.needsStatusRefresh(
                changedPaths: paths, worktreeRoots: roots, managementDirectories: git.managementDirectories
            ) { git.refresh() }
        }
    }

    func checkForExternalChanges() {
        activeEditor.local.checkForExternalChanges()
        activeEditor.local.refreshDiffs()
        explorer.refresh()
        git.refresh()
    }

    func refresh() {
        refreshID += 1
        activeEditor.refresh()
        git.refresh()
        if let root = explorer.selectedLocation { remoteGitStores[root]?.refresh() }
    }

    func remoteGit(for root: FileLocation, hosts: [RemoteHost], connections: RemoteConnectionStore,
                   servers: RemoteServerStore) -> RemoteGitStore? {
        guard case let .remote(hostID, _) = root,
              let host = hosts.first(where: { $0.persistentModelID == hostID }) else { return nil }
        if let store = remoteGitStores[root] { return store }
        let store = RemoteGitStore(root: root, host: host, connections: connections, servers: servers)
        remoteGitStores[root] = store
        return store
    }

    func releaseRemoteGit(for root: FileLocation) {
        remoteGitStores.removeValue(forKey: root)?.stop()
    }

    func preview(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) {
        guard !isInRemoteFileOperation(location) else { return }
        prepare(location, hosts: hosts, connections: connections, servers: servers)
        activeEditor.preview(.file(location))
    }

    func open(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        guard !isInRemoteFileOperation(location) else { return }
        prepare(location, hosts: hosts, connections: connections, servers: servers, root: root)
        activeEditor.open(.file(location))
    }

    func openDiff(_ location: FileLocation, preview: Bool = false) {
        guard !isInRemoteFileOperation(location) else { return }
        if case .remote = location {
            if preview { activeEditor.preview(.diff(location)) }
            else { activeEditor.open(.diff(location)) }
            return
        }
        guard let url = location.localURL else { return }
        let fileURL = url.standardizedFileURL
        activeEditor.local.loadDiff(at: fileURL)
        if preview { activeEditor.preview(.diff(.local(fileURL))) }
        else { activeEditor.open(.diff(.local(fileURL))) }
    }

    func openMarkdownPreview(_ location: FileLocation) {
        guard !isInRemoteFileOperation(location) else { return }
        guard EditorStore.supportsMarkdownPreview(location) else { return }
        activeEditor.local.load(location)
        activeEditor.open(.file(location))
        activeEditor.setMarkdownPreviewVisible(true, for: location)
    }

    private func prepare(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        switch location {
        case .local:
            activeEditor.local.load(location)
        case .remote:
            activeEditor.remote.load(location, root: root ?? explorer.treeLocation,
                               hosts: hosts.compactMap { $0 as? RemoteHost }, connections: connections, servers: servers)
        }
    }

    enum OperationError: LocalizedError {
        case invalidName
        case editing(String)
        case resultUnknown(String)
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case .invalidName: "名前には空文字・.・..・/・:・制御文字を使用できません。"
            case let .editing(name): "\(name)は未保存・入力中・保存中です。保存してから操作してください。"
            case let .resultUnknown(message): "操作結果を確認できませんでした。再実行する前にリモートの状態を確認してください。\n\(message)"
            case .operationInProgress: "リモートファイルの操作中です。"
            }
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw OperationError.invalidName }
    }

    private func destination(in directory: URL, name: String) throws -> URL {
        try validateName(name)
        let url = directory.appendingPathComponent(name)
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            throw CocoaError(.fileWriteFileExists)
        }
        return url
    }

    func commitName() throws {
        guard let edit = explorer.nameEdit else { return }
        guard let target = edit.target.localURL else { return }
        switch edit.operation {
        case .rename: try rename(target, to: edit.name)
        case .newFile: try create(in: target, name: edit.name, isDirectory: false)
        case .newFolder: try create(in: target, name: edit.name, isDirectory: true)
        }
        explorer.cancelNameEditing()
    }

    func commitRemoteName(hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        guard !isCommittingRemoteName, let edit = explorer.nameEdit else { return }
        isCommittingRemoteName = true
        defer { isCommittingRemoteName = false }
        let target = edit.target
        let name = edit.name
        try validateName(name)
        if edit.operation == .rename, name == target.name { explorer.cancelNameEditing(); return }
        let affected = edit.operation == .rename ? try editableTabs(under: target) : []
        let locked = try edit.operation == .rename ? beginRemoteFileOperation(target, affected: affected) : []
        defer { if edit.operation == .rename { endRemoteFileOperation(locked) } }
        let (client, root, path) = try await remoteOperation(target, hosts: hosts, connections: connections, servers: servers)
        do {
            switch edit.operation {
            case .rename: try await client.files.rename(root: root, path: path, name: name)
            case .newFile: try await client.files.createFile(root: root, path: path.isEmpty ? name : path + "/" + name)
            case .newFolder: try await client.files.createDirectory(root: root, path: path.isEmpty ? name : path + "/" + name)
            }
        } catch { throw operationError(error) }
        for (editor, tab) in affected { editor.closeAfterFileOperation(tab) }
        if explorer.nameEdit?.item === edit.item { explorer.cancelNameEditing() }
        refreshID += 1
        if let root = explorer.selectedLocation { remoteGitStores[root]?.refresh() }
    }

    func trashRemote(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let affected = try editableTabs(under: location)
        let locked = try beginRemoteFileOperation(location, affected: affected)
        defer { endRemoteFileOperation(locked) }
        let (client, root, path) = try await remoteOperation(location, hosts: hosts, connections: connections, servers: servers)
        do { try await client.files.trash(root: root, path: path) }
        catch { throw operationError(error) }
        for (editor, tab) in affected { editor.closeAfterFileOperation(tab) }
        refreshID += 1
        if let root = explorer.selectedLocation { remoteGitStores[root]?.refresh() }
    }

    private func operationError(_ error: Error) -> Error {
        if let clientError = error as? WhubClientError, case .api = clientError { return error }
        return OperationError.resultUnknown(error.localizedDescription)
    }

    private func isInRemoteFileOperation(_ location: FileLocation) -> Bool {
        guard let target = remoteFileOperation,
              case let .remote(host, path) = target, case let .remote(otherHost, otherPath) = location else { return false }
        return host == otherHost && (otherPath == path || otherPath.hasPrefix(path == "/" ? "/" : path + "/"))
    }

    private func beginRemoteFileOperation(_ location: FileLocation, affected: [(EditorStore, EditorTab)]) throws -> [RemoteFileStore] {
        guard remoteFileOperation == nil else { throw OperationError.operationInProgress }
        remoteFileOperation = location
        let files = affected.compactMap { editor, tab -> RemoteFileStore? in
            guard case let .file(location) = tab else { return nil }
            return editor.remote.fileStores[location]
        }
        for file in files { file.isFileOperationLocked = true }
        return files
    }

    private func endRemoteFileOperation(_ files: [RemoteFileStore]) {
        for file in files { file.isFileOperationLocked = false }
        remoteFileOperation = nil
    }

    private func remoteOperation(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore,
                                 servers: RemoteServerStore) async throws -> (WhubClient, String, String) {
        guard case let .remote(hostID, path) = location, case let .remote(rootHost, root) = explorer.selectedLocation,
              hostID == rootHost, let host = hosts.compactMap({ $0 as? RemoteHost }).first(where: { $0.persistentModelID == hostID }),
              connections.connection(for: host) != nil else { throw SSHError.disconnected }
        let prefix = root == "/" ? "/" : root + "/"
        guard path == root || path.hasPrefix(prefix) else { throw WhubClientError.invalidPath }
        let client = try await servers.client(for: host)
        return (client, root, path == root ? "" : String(path.dropFirst(prefix.count)))
    }

    private func editableTabs(under location: FileLocation) throws -> [(EditorStore, EditorTab)] {
        var affected: [(EditorStore, EditorTab)] = []
        for editor in editorsByWorkspace.values {
            do { affected += try editor.tabsForFileOperation(under: location).map { (editor, $0) } }
            catch let EditorStore.FileOperationError.editing(name) { throw OperationError.editing(name) }
        }
        return affected
    }

    func create(in directory: URL, name: String, isDirectory: Bool) throws {
        let url = try destination(in: directory, name: name)
        if isDirectory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } else {
            try Data().write(to: url, options: .withoutOverwriting)
        }
        checkForExternalChanges()
    }

    func rename(_ url: URL, to name: String) throws {
        let affected = try editableTabs(under: .local(url))
        if name == url.lastPathComponent { return }
        let target = try destination(in: url.deletingLastPathComponent(), name: name)
        try FileManager.default.moveItem(at: url, to: target)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
    }

    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        let affected = try editableTabs(under: .local(url))
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
        return result as URL?
    }

}
