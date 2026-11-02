import Combine
import Foundation
import WhubCore

@MainActor
final class FilesStore: ObservableObject {
    let explorer = ExplorerStore()
    @Published private(set) var activeEditor = EditorStore()
    private var editorsByWorkspace: [FileLocation?: EditorStore] = [:]
    private var workspaceChanges: AnyCancellable?
    let git = GitStore()
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
        explorer.localTree.onChanges = { [weak self] event, worktreeChanged in
            guard let self, let root = explorer.rootURL else { return }
            git.handleFileChanges(event, worktreeChanged: worktreeChanged, root: root)
        }
    }

    func checkForExternalChanges() {
        activeEditor.checkForExternalChanges()
        explorer.refresh()
        git.refresh()
    }

    func refresh() {
        refreshID += 1
        activeEditor.refresh()
        git.refresh()
        if let root = explorer.selectedLocation { git.remoteGitStores[root]?.refresh() }
    }

    func preview(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) {
        guard !isInRemoteFileOperation(location) else { return }
        activeEditor.preview(location, hosts: hosts, connections: connections, servers: servers, root: explorer.treeLocation)
    }

    func open(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        guard !isInRemoteFileOperation(location) else { return }
        activeEditor.open(location, hosts: hosts, connections: connections, servers: servers, root: root ?? explorer.treeLocation)
    }

    func openDiff(_ location: FileLocation, preview: Bool = false) {
        guard !isInRemoteFileOperation(location) else { return }
        activeEditor.openDiff(location, preview: preview)
    }

    func openMarkdownPreview(_ location: FileLocation) {
        guard !isInRemoteFileOperation(location) else { return }
        activeEditor.openMarkdownPreview(location)
    }

    enum OperationError: LocalizedError {
        case editing(String)
        case operationInProgress

        var errorDescription: String? {
            switch self {
            case let .editing(name): "\(name)は未保存・入力中・保存中です。保存してから操作してください。"
            case .operationInProgress: "リモートファイルの操作中です。"
            }
        }
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
        try FileOperation.validateName(name)
        if edit.operation == .rename, name == target.name { explorer.cancelNameEditing(); return }
        let affected = edit.operation == .rename ? try editableTabs(under: target) : []
        let locked = try edit.operation == .rename ? beginRemoteFileOperation(target, affected: affected) : []
        defer { if edit.operation == .rename { endRemoteFileOperation(locked) } }
        try await FileOperation.commitRemoteName(edit.operation, target: target, name: name,
                                                 selectedRoot: explorer.selectedLocation, hosts: hosts,
                                                 connections: connections, servers: servers)
        for (editor, tab) in affected { editor.closeAfterFileOperation(tab) }
        explorer.finishNameEditing(edit)
        refreshID += 1
        if let root = explorer.selectedLocation { git.remoteGitStores[root]?.refresh() }
    }

    func trashRemote(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let affected = try editableTabs(under: location)
        let locked = try beginRemoteFileOperation(location, affected: affected)
        defer { endRemoteFileOperation(locked) }
        try await FileOperation.trashRemote(location, selectedRoot: explorer.selectedLocation, hosts: hosts,
                                            connections: connections, servers: servers)
        for (editor, tab) in affected { editor.closeAfterFileOperation(tab) }
        refreshID += 1
        if let root = explorer.selectedLocation { git.remoteGitStores[root]?.refresh() }
    }

    private func isInRemoteFileOperation(_ location: FileLocation) -> Bool {
        guard let target = remoteFileOperation,
              case let .remote(host, path) = target, case let .remote(otherHost, otherPath) = location else { return false }
        return host == otherHost && (otherPath == path || otherPath.hasPrefix(path == "/" ? "/" : path + "/"))
    }

    private func beginRemoteFileOperation(_ location: FileLocation, affected: [(EditorStore, EditorTab)]) throws -> [EditorStore.FileOperationLock] {
        guard remoteFileOperation == nil else { throw OperationError.operationInProgress }
        remoteFileOperation = location
        return affected.map { editor, tab in editor.lockForFileOperation(tab) }
    }

    private func endRemoteFileOperation(_ locks: [EditorStore.FileOperationLock]) {
        for lock in locks { lock.unlock() }
        remoteFileOperation = nil
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
        try FileOperation.create(in: directory, name: name, isDirectory: isDirectory)
        checkForExternalChanges()
    }

    func rename(_ url: URL, to name: String) throws {
        let affected = try editableTabs(under: .local(url))
        if name == url.lastPathComponent { return }
        try FileOperation.rename(url, to: name)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
    }

    func move(_ url: URL, to directory: URL) throws {
        let affected = try editableTabs(under: .local(url))
        try FileOperation.move(url, to: directory)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
    }

    func moveRemote(_ location: FileLocation, to directory: FileLocation, hosts: [WhubCore.Host],
                    connections: RemoteConnectionStore, servers: RemoteServerStore) async throws {
        let affected = try editableTabs(under: location)
        let locked = try beginRemoteFileOperation(location, affected: affected)
        defer { endRemoteFileOperation(locked) }
        try await FileOperation.moveRemote(location, to: directory, selectedRoot: explorer.selectedLocation,
                                           hosts: hosts, connections: connections, servers: servers)
        for (editor, tab) in affected { editor.closeAfterFileOperation(tab) }
        refreshID += 1
        if let root = explorer.selectedLocation { git.remoteGitStores[root]?.refresh() }
    }

    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        let affected = try editableTabs(under: .local(url))
        let result = try FileOperation.trash(url)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
        return result
    }

}
