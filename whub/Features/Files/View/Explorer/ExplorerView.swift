import AppKit
import SwiftData
import SwiftUI
import WhubCore
import WhubGit

struct ExplorerSidebar: View {
    let onFileSelect: () -> Void
    let onOpenInBrowser: (URL) -> Void
    let focus: ExplorerFocusNavigation
    @EnvironmentObject private var files: FilesStore

    var body: some View {
        ExplorerView(onFileSelect: onFileSelect, onOpenInBrowser: onOpenInBrowser, store: files.explorer,
                     focus: focus)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 640)
    }
}

struct ExplorerView: View {
    let onFileSelect: () -> Void
    let onOpenInBrowser: (URL) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var servers: RemoteServerStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var gitStore: GitStore
    @ObservedObject var store: ExplorerStore
    let focus: ExplorerFocusNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExplorerPulldownView(store: store)
            if store.showsDiff, let root = store.selectedLocation, case .remote = root,
               let remoteGit = files.remoteGit(for: root, hosts: hosts.compactMap { $0 as? RemoteHost },
                                               connections: connections, servers: servers) {
                RemoteExplorerDiffView(git: remoteGit, editor: files.activeEditor, focus: focus,
                                       onPreview: { openDiff($0, preview: true) },
                                       onOpen: { openDiff($0, preview: false) }, onShowMarkdownPreview: showMarkdownPreview)
                    .id(root)
            } else if store.showsDiff, store.selectedLocation?.localURL != nil {
                ExplorerDiffView(git: gitStore, editor: files.activeEditor,
                                 focus: focus,
                                 onPreview: { openDiff($0, preview: true) },
                                 onOpen: { openDiff($0, preview: false) },
                                 onShowMarkdownPreview: showMarkdownPreview)
            } else if let root = store.selectedLocation, case .remote = root,
                      let remoteGit = files.remoteGit(for: root, hosts: hosts.compactMap { $0 as? RemoteHost },
                                                      connections: connections, servers: servers) {
                RemoteTreeGitView(git: remoteGit) { changes in explorerTree(remoteChanges: changes) }
                    .id(root)
            } else {
                explorerTree(remoteChanges: [:])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TabPaneFocusView(focus: focus.sidebar))
        .focusedSceneValue(\.toggleExplorerDiff, { setShowsDiff(!store.showsDiff) })
        .onChange(of: store.showsDiff, initial: true) { gitStore.setDiffEnabled(store.showsDiff) }
        .onAppear {
            focus.onEditorFocus = { [weak store = store] location in store?.revealInTree(location) }
            store.startWatching()
        }
        .onDisappear { focus.onEditorFocus = nil; store.stopWatching() }
        .task(id: store.updateID(projects: projects, hosts: hosts, connections: connections,
                                 refreshID: files.refreshID)) {
            await store.update(projects: projects, hosts: hosts, connections: connections, servers: servers,
                               refreshID: files.refreshID, context: context)
        }
    }

    private func explorerTree(remoteChanges: [FileLocation: GitChange]) -> some View {
        ExplorerTreeView(
            store: store, gitStore: gitStore, remoteChanges: remoteChanges, focus: focus,
            onFilePreview: { location in
                files.preview(location, hosts: hosts, connections: connections, servers: servers)
                onFileSelect()
            },
            onFileOpen: { location in
                files.open(location, hosts: hosts, connections: connections, servers: servers)
                onFileSelect()
            },
            onShowDiff: { openDiff($0, preview: false) }, onAction: performAction, onCommitName: commitName
        )
    }

    private func performAction(_ action: ExplorerContextMenu.Action, location: FileLocation) {
        do {
            switch action {
            case .openInBrowser:
                if let url = location.localURL { onOpenInBrowser(url) }
            case .showPreview:
                showMarkdownPreview(location)
            case .trash:
                let alert = NSAlert()
                alert.messageText = "\(location.name)をゴミ箱に移動しますか？"
                alert.addButton(withTitle: "キャンセル")
                alert.addButton(withTitle: "ゴミ箱に移動")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                if let url = location.localURL { try files.trash(url) }
                else {
                    Task {
                        do { try await files.trashRemote(location, hosts: hosts, connections: connections, servers: servers) }
                        catch { EditorDialogs.show(error: error) }
                    }
                }
            }
        } catch {
            EditorDialogs.show(error: error)
        }
    }

    private func commitName() throws {
        guard case .remote = store.nameEdit?.target else { try files.commitName(); return }
        Task {
            do { try await files.commitRemoteName(hosts: hosts, connections: connections, servers: servers) }
            catch { EditorDialogs.show(error: error) }
        }
    }

    private func showMarkdownPreview(_ location: FileLocation) {
        if case .remote = location {
            files.open(location, hosts: hosts, connections: connections, servers: servers)
            files.activeEditor.setMarkdownPreviewVisible(true, for: location)
        } else { files.openMarkdownPreview(location) }
        onFileSelect()
    }

    private func setShowsDiff(_ value: Bool) {
        if let window = focus.sidebar.view?.window, focus.containsExplorer(window) {
            focus.sidebar.activate()
        }
        store.showsDiff = value
    }

    private func openDiff(_ location: FileLocation, preview: Bool) {
        files.openDiff(location, preview: preview)
        onFileSelect()
    }
}

extension EnvironmentValues {
    @Entry var explorerFocusNavigation: ExplorerFocusNavigation? = nil
}

private struct ToggleExplorerFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ToggleExplorerDiffKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var toggleExplorerDiff: (() -> Void)? {
        get { self[ToggleExplorerDiffKey.self] }
        set { self[ToggleExplorerDiffKey.self] = newValue }
    }
    var toggleExplorerFocus: (() -> Void)? {
        get { self[ToggleExplorerFocusKey.self] }
        set { self[ToggleExplorerFocusKey.self] = newValue }
    }
}

final class ExplorerFocusNavigation {
    var onEditorFocus: ((FileLocation) -> Void)?
    let sidebar = TabPaneFocus()
    let content = TabPaneFocus()
    weak var list: NSTableView?
    private weak var previousContentResponder: NSView?
    private let lastEditors = NSMapTable<FileStore, CodeTextView>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .weakMemory
    )

    func rememberEditorPosition(_ editor: CodeTextView) {
        guard let document = editor.fileStore, let window = content.view?.window,
              editor.window === window else { return }
        lastEditors.setObject(editor, forKey: document)
    }

    @discardableResult
    func inheritEditorPosition(_ editor: CodeTextView) -> Bool {
        guard let document = editor.fileStore, let editorID = editor.editorID,
              let window = content.view?.window, editor.window === window,
              let previous = lastEditors.object(forKey: document), previous !== editor,
              let previousID = previous.editorID,
              let position = document.editorPositions[previousID] else { return false }
        document.editorPositions[editorID] = position
        lastEditors.setObject(editor, forKey: document)
        return true
    }

    func attachList(_ table: NSTableView) {
        list = table
        DispatchQueue.main.async { [weak self, weak table] in
            guard let self, let table, self.list === table,
                  let window = table.window, !table.isHiddenOrHasHiddenAncestor,
                  window.firstResponder === self.sidebar.view else { return }
            window.makeFirstResponder(table)
        }
    }

    func containsExplorer(_ window: NSWindow) -> Bool {
        if let list, window.firstResponder === list { return true }
        return sidebar.contains(window)
    }

    func toggle(prefersEditor: Bool) {
        guard let window = content.view?.window, window.attachedSheet == nil else { return }
        if containsExplorer(window) {
            guard let root = content.view else { return }
            let remembered = previousContentResponder.flatMap {
                $0.isDescendant(of: root) && !$0.isHiddenOrHasHiddenAncestor ? $0 : nil
            }
            let target = prefersEditor
                ? (remembered as? CodeTextView) ?? find(in: root, matching: { $0 is CodeTextView }) ?? remembered
                : remembered
            if let target = target ?? find(in: root, matching: { $0.acceptsFirstResponder }) {
                window.makeFirstResponder(target)
            }
        } else {
            if content.contains(window) { previousContentResponder = window.firstResponder as? NSView }
            if let list, list.window === window, !list.isHiddenOrHasHiddenAncestor {
                window.makeFirstResponder(list)
            } else { sidebar.activate() }
        }
    }

    private func find(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        for child in view.subviews {
            if let match = find(in: child, matching: predicate) { return match }
        }
        return predicate(view) ? view : nil
    }
}
