import Combine
import Foundation
import WhubCore

@MainActor
final class FilesStore: ObservableObject {
    let explorer = ExplorerStore()
    let editor = EditorStore()
    let git = GitStore()
    @Published private(set) var refreshID = 0
    private var rootChanges: AnyCancellable?

    init() {
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
        editor.local.checkForExternalChanges()
        editor.local.refreshDiffs()
        explorer.refresh()
        git.refresh()
    }

    func refresh() {
        refreshID += 1
        editor.refresh()
        git.refresh()
    }

    func preview(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore) {
        prepare(location, hosts: hosts, connections: connections)
        editor.preview(.file(location))
    }

    func open(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore) {
        prepare(location, hosts: hosts, connections: connections)
        editor.open(.file(location))
    }

    func openDiff(_ location: FileLocation, preview: Bool = false) {
        guard let url = location.localURL else { return }
        let fileURL = url.standardizedFileURL
        editor.local.loadDiff(at: fileURL)
        if preview { editor.preview(.diff(fileURL)) }
        else { editor.open(.diff(fileURL)) }
    }

    private func prepare(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore) {
        switch location {
        case .local:
            editor.local.load(location)
        case .remote:
            editor.remote.load(location, root: explorer.treeLocation,
                               hosts: hosts.compactMap { $0 as? RemoteHost }, connections: connections)
        }
    }

}
