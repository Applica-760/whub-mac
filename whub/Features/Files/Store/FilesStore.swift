import Combine
import Foundation
import SwiftData
import WhubCore
import WhubGit

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
        prepare(location, hosts: hosts, connections: connections, servers: servers)
        activeEditor.preview(.file(location))
    }

    func open(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) {
        prepare(location, hosts: hosts, connections: connections, servers: servers)
        activeEditor.open(.file(location))
    }

    func openDiff(_ location: FileLocation, preview: Bool = false) {
        guard let url = location.localURL else { return }
        let fileURL = url.standardizedFileURL
        activeEditor.local.loadDiff(at: fileURL)
        if preview { activeEditor.preview(.diff(.local(fileURL))) }
        else { activeEditor.open(.diff(.local(fileURL))) }
    }

    func openMarkdownPreview(_ location: FileLocation) {
        guard EditorStore.supportsMarkdownPreview(location) else { return }
        activeEditor.local.load(location)
        activeEditor.open(.file(location))
        activeEditor.setMarkdownPreviewVisible(true, for: location)
    }

    private func prepare(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore) {
        switch location {
        case .local:
            activeEditor.local.load(location)
        case .remote:
            activeEditor.remote.load(location, root: explorer.treeLocation,
                               hosts: hosts.compactMap { $0 as? RemoteHost }, connections: connections, servers: servers)
        }
    }

    enum OperationError: LocalizedError {
        case invalidName
        case editing(String)

        var errorDescription: String? {
            switch self {
            case .invalidName: "名前には空文字・.・..・/・:・制御文字を使用できません。"
            case let .editing(name): "\(name)は未保存・入力中・保存中です。保存してから操作してください。"
            }
        }
    }

    private func destination(in directory: URL, name: String) throws -> URL {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw OperationError.invalidName }
        let url = directory.appendingPathComponent(name)
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            throw CocoaError(.fileWriteFileExists)
        }
        return url
    }

    func commitName() throws {
        guard let edit = explorer.nameEdit else { return }
        switch edit.operation {
        case .rename: try rename(edit.target, to: edit.name)
        case .newFile: try create(in: edit.target, name: edit.name, isDirectory: false)
        case .newFolder: try create(in: edit.target, name: edit.name, isDirectory: true)
        }
        explorer.cancelNameEditing()
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
        let affected = try editableTabs(under: url)
        if name == url.lastPathComponent { return }
        let target = try destination(in: url.deletingLastPathComponent(), name: name)
        try FileManager.default.moveItem(at: url, to: target)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
    }

    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        let affected = try editableTabs(under: url)
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        for (editor, tab) in affected { editor.close(tab) }
        checkForExternalChanges()
        return result as URL?
    }

    private func editableTabs(under url: URL) throws -> [(EditorStore, EditorTab)] {
        var affected: [(EditorStore, EditorTab)] = []
        for editor in editorsByWorkspace.values {
            do {
                affected += try editor.tabsForFileOperation(under: url).map { (editor, $0) }
            } catch let EditorStore.FileOperationError.editing(name) {
                throw OperationError.editing(name)
            }
        }
        return affected
    }

}
