import Combine
import Foundation

final class EditorStore: ObservableObject {
    @Published private(set) var tabs: [EditorTab] = []
    @Published private(set) var selectedTab: EditorTab?
    @Published private(set) var previewTab: EditorTab?
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

    func refresh() {
        remote.refresh()
        local.refreshDiffs()
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
        if case let .file(previous) = previewTab, local.fileStores[previous]?.document.hasUnsavedChanges == true {
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
        defer { isClosing = false }
        if case let .file(file) = tab, local.fileStores[file]?.confirmClose() == false { return }
        guard let index = tabs.firstIndex(of: tab) else { return }
        tabs.remove(at: index)
        release(tab)
        if previewTab == tab { previewTab = nil }
        guard selectedTab == tab else { return }
        selectedTab = index < tabs.count ? tabs[index] : tabs.last
    }

    func move(_ tab: EditorTab, before target: EditorTab?) {
        guard let reordered = reorderedTabs(tabs, moving: tab, before: target, identifiedBy: \.self)
        else { return }
        tabs = reordered
        if previewTab == tab { previewTab = nil }
    }

    private func isPrepared(_ tab: EditorTab) -> Bool {
        switch tab {
        case let .file(location): local.fileStores[location] != nil || remote.states[location] != nil
        case let .diff(url): local.diffStores[url] != nil
        }
    }

    private func release(_ tab: EditorTab) {
        switch tab {
        case let .file(location):
            local.close(location)
            remote.close(location)
        case let .diff(url): local.closeDiff(at: url)
        }
    }

    func select(_ tab: EditorTab) {
        guard tabs.contains(tab) else { return }
        selectedTab = tab
    }
}
