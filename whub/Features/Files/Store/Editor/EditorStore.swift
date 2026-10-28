import Combine
import Foundation

final class EditorStore: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var selectedTab: EditorTab?
    @Published private(set) var previewTab: EditorTab?
    @Published private(set) var markdownPreviews: Set<FileLocation> = []
    let local = LocalEditorStore()
    let remote = RemoteEditorStore()
    private var changes: AnyCancellable?
    private var isClosing = false

    init() {
        changes = Publishers.Merge(local.objectWillChange, remote.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func file(for location: FileLocation) -> FileStore? {
        local.fileStores[location]?.document ?? remote.file(for: location)
    }

    static func supportsMarkdownPreview(_ location: FileLocation) -> Bool {
        (location.path as NSString).pathExtension.lowercased() == "md"
    }

    var markdownPreviewLocation: FileLocation? {
        guard case let .file(location) = selectedTab, Self.supportsMarkdownPreview(location),
              case .text = file(for: location)?.content else { return nil }
        return location
    }

    func setMarkdownPreviewVisible(_ visible: Bool, for location: FileLocation) {
        if visible {
            guard Self.supportsMarkdownPreview(location), tabs.contains(.file(location)) else { return }
            if case .local = location {
                guard case .text = file(for: location)?.content else { return }
            }
            markdownPreviews.insert(location)
        } else {
            markdownPreviews.remove(location)
        }
    }

    func refresh() {
        remote.refresh()
        local.refresh()
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

    func open(_ tab: EditorTab) {
        guard isPrepared(tab) else { return }
        if !tabs.contains(tab) {
            tabs.append(tab)
        }
        selectedTab = tab
        if previewTab == tab { previewTab = nil }
    }

    func preview(_ tab: EditorTab) {
        guard isPrepared(tab) else { return }
        if tabs.contains(tab) && previewTab != tab {
            selectedTab = tab
            return
        }
        if case let .file(previous) = previewTab,
           file(for: previous)?.hasUnsavedChanges == true || file(for: previous)?.editorViews.hasMarkedText == true
            || remote.fileStores[previous]?.needsCloseConfirmation == true {
            previewTab = nil
        }
        if let previewTab, let index = tabs.firstIndex(of: previewTab) {
            if previewTab != tab {
                release(previewTab)
            }
            tabs[index] = tab
        } else if !tabs.contains(tab) {
            tabs.append(tab)
        }
        previewTab = tab
        selectedTab = tab
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
        defer { isClosing = false }
        if case let .file(file) = tab, local.fileStores[file]?.confirmClose() == false { return }
        finishClose(tab)
    }

    private func finishClose(_ tab: EditorTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        release(tab)
        if previewTab == tab { previewTab = nil }
        guard selectedTab == tab else { return }
        selectedTab = index < tabs.count ? tabs[index] : tabs.last
    }

    func closeAfterFileOperation(_ tab: EditorTab) {
        finishClose(tab)
    }

    func move(_ tab: EditorTab, before target: EditorTab?) {
        guard let reordered = reorderedTabs(tabs, moving: tab, before: target, identifiedBy: \.self)
        else { return }
        tabs = reordered
        if previewTab == tab { previewTab = nil }
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
            markdownPreviews.remove(location)
            local.close(location)
            remote.close(location)
        case let .diff(location):
            if let url = location.localURL { local.closeDiff(at: url) }
        }
    }

    func select(_ tab: EditorTab) {
        guard tabs.contains(tab) else { return }
        selectedTab = tab
    }
}
