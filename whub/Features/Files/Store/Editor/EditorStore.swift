import Combine
import Foundation
import WhubCore

final class EditorStore: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var selectedTab: EditorTab?
    @Published private(set) var temporaryTab: EditorTab?
    @Published private var requestedMarkdownPreviews: Set<FileLocation> = []
    let local = LocalEditorStore()
    let remote = RemoteEditorStore()
    private var changes: AnyCancellable?
    private var isClosing = false

    init() {
        changes = Publishers.Merge(local.objectWillChange, remote.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func open(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        prepare(location, hosts: hosts, connections: connections, servers: servers, root: root)
        open(.file(location))
    }

    func open(_ tab: EditorTab) {
        guard isPrepared(tab) else { return }
        if !tabs.contains(tab) {
            tabs.append(tab)
        }
        selectedTab = tab
        if temporaryTab == tab { temporaryTab = nil }
    }

    func openTemporaryTab(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        prepare(location, hosts: hosts, connections: connections, servers: servers, root: root)
        openTemporaryTab(.file(location))
    }

    func openTemporaryTab(_ tab: EditorTab) {
        guard isPrepared(tab) else { return }
        if tabs.contains(tab) && temporaryTab != tab {
            selectedTab = tab
            return
        }
        if case let .file(previous) = temporaryTab,
           file(for: previous)?.hasUnsavedChanges == true || file(for: previous)?.editorViews.hasMarkedText == true
            || local.fileStores[previous]?.isSaving == true
            || remote.fileStores[previous]?.needsCloseConfirmation == true {
            temporaryTab = nil
        }
        if let temporaryTab, let index = tabs.firstIndex(of: temporaryTab) {
            if temporaryTab != tab {
                release(temporaryTab)
            }
            tabs[index] = tab
        } else if !tabs.contains(tab) {
            tabs.append(tab)
        }
        temporaryTab = tab
        selectedTab = tab
    }

    func select(_ tab: EditorTab) {
        guard tabs.contains(tab) else { return }
        selectedTab = tab
    }

    func move(_ tab: EditorTab, before target: EditorTab?) {
        guard let reordered = reorderedTabs(tabs, moving: tab, before: target, identifiedBy: \.self)
        else { return }
        tabs = reordered
        if temporaryTab == tab { temporaryTab = nil }
    }

    func openDiff(_ location: FileLocation, temporary: Bool = false) {
        if case .remote = location {
            if temporary { self.openTemporaryTab(.diff(location)) }
            else { open(.diff(location)) }
            return
        }
        guard let url = location.localURL else { return }
        let fileURL = url.standardizedFileURL
        local.loadDiff(at: fileURL)
        if temporary { self.openTemporaryTab(.diff(.local(fileURL))) }
        else { open(.diff(.local(fileURL))) }
    }

    func openMarkdownPreview(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore,
                             servers: RemoteServerStore, root: FileLocation? = nil) {
        guard location.kind.isMarkdown else { return }
        open(location, hosts: hosts, connections: connections, servers: servers, root: root)
        setMarkdownPreviewVisible(true, for: location)
    }

    var markdownPreviews: Set<FileLocation> {
        requestedMarkdownPreviews.filter { location in
            guard let file = local.fileStores[location], !file.isLoading else { return true }
            if case .text = file.document.content { return true }
            return false
        }
    }

    func setMarkdownPreviewVisible(_ visible: Bool, for location: FileLocation) {
        if visible {
            guard location.kind.isMarkdown, tabs.contains(.file(location)) else { return }
            requestedMarkdownPreviews.insert(location)
        } else {
            requestedMarkdownPreviews.remove(location)
        }
    }

    private func prepare(_ location: FileLocation, hosts: [WhubCore.Host], connections: RemoteConnectionStore, servers: RemoteServerStore, root: FileLocation? = nil) {
        switch location {
        case .local:
            local.load(location)
        case .remote:
            remote.load(location, root: root,
                               hosts: hosts.compactMap { $0 as? RemoteHost }, connections: connections, servers: servers)
        }
    }

    func file(for location: FileLocation) -> EditContentStore? {
        if let file = local.fileStores[location] { return file.isLoading ? nil : file.document }
        return remote.file(for: location)
    }

    func refresh() {
        remote.refresh()
        local.refresh()
    }

    func checkForExternalChanges() {
        local.checkForExternalChanges()
        local.refreshDiffs()
    }

    struct FileOperationLock {
        fileprivate let files: [RemoteFileStore]

        func unlock() {
            for file in files { file.isFileOperationLocked = false }
        }
    }

    func lockForFileOperation(_ tab: EditorTab) -> FileOperationLock {
        let files: [RemoteFileStore]
        if case let .file(location) = tab, let file = remote.fileStores[location] {
            files = [file]
        } else {
            files = []
        }
        for file in files { file.isFileOperationLocked = true }
        return FileOperationLock(files: files)
    }

    enum FileOperationError: Error {
        case editing(String)
    }

    func tabsForFileOperation(under location: FileLocation) throws -> [EditorTab] {
        return try tabs.filter { tab in
            let target: FileLocation
            switch tab {
            case let .file(value), let .diff(value): target = value
            }
            let matches: Bool
            switch (location, target) {
            case let (.local(root), .local(url)):
                let roots = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
                let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
                matches = paths.contains { path in roots.contains { path == $0 || path.hasPrefix($0 + "/") } }
            case let (.remote(hostID, path), .remote(targetHost, targetPath)):
                matches = targetHost == hostID && (targetPath == path || targetPath.hasPrefix(path + "/"))
            default: matches = false
            }
            guard matches else { return false }
            if case .file = tab,
               local.fileStores[target]?.blocksFileOperation == true || remote.fileStores[target]?.needsCloseConfirmation == true {
                throw FileOperationError.editing(target.name)
            }
            return true
        }
    }

    func close(_ tab: EditorTab) {
        guard !isClosing, tabs.contains(tab) else { return }
        isClosing = true
        if case let .file(file) = tab, let remoteFile = remote.fileStores[file],
           remoteFile.needsCloseConfirmation {
            Task { @MainActor in
                defer { isClosing = false }
                guard await remoteFile.confirmClose() else { return }
                finishClose(tab)
            }
            return
        }
        if case let .file(file) = tab, let localFile = local.fileStores[file], localFile.blocksFileOperation {
            Task { @MainActor in
                defer { isClosing = false }
                guard await localFile.confirmClose() else { return }
                finishClose(tab)
            }
            return
        }
        defer { isClosing = false }
        finishClose(tab)
    }

    private func finishClose(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        release(tab)
        if temporaryTab == tab { temporaryTab = nil }
        guard selectedTab == tab else { return }
        selectedTab = index < tabs.count ? tabs[index] : tabs.last
    }

    func closeAfterFileOperation(_ tab: EditorTab) {
        finishClose(tab)
    }

    private func isPrepared(_ tab: EditorTab) -> Bool {
        switch tab {
        case let .file(location): return local.fileStores[location] != nil || remote.states[location] != nil
        case let .diff(location):
            if case .remote = location { return true }
            return location.localURL.map { local.diffStores[$0] != nil } ?? false
        }
    }

    private func release(_ tab: EditorTab) {
        switch tab {
        case let .file(location):
            requestedMarkdownPreviews.remove(location)
            local.close(location)
            remote.close(location)
        case let .diff(location):
            if let url = location.localURL { local.closeDiff(at: url) }
        }
    }

}
