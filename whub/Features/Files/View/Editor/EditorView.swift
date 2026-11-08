import Combine
import SwiftData
import SwiftUI
import WhubCore

private struct ToggleFileDiffKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var toggleFileDiff: (() -> Void)? {
        get { self[ToggleFileDiffKey.self] }
        set { self[ToggleFileDiffKey.self] = newValue }
    }
}

struct FileDiffMenu: View {
    @ObservedObject var editor: EditorStore
    let isEditingName: Bool
    @FocusedValue(\.toggleFileDiff) private var toggleFileDiff

    var body: some View {
        Button("Toggle File Diff") { toggleFileDiff?() }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(toggleFileDiff == nil || editor.selectedTab == nil || isEditingName)
    }
}

struct EditorView: View {
    @State private var tabFocus = TabPaneFocus()
    @State private var wasActive = false
    @State private var focusRequest = UUID()
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var servers: RemoteServerStore
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.explorerFocusNavigation) private var explorerFocus
    @State private var editorID = UUID().uuidString

    var body: some View {
        WidgetFrame {
            switch store.selectedTab {
            case let .file(.local(url)):
                LocalFileView(fileURL: url, editorID: editorID)
            case let .file(.remote(hostID, path)):
                RemoteFileView(hostID: hostID, path: path, editorID: editorID)
            case let .diff(.local(url)):
                LocalDiffView(fileURL: url)
            case let .diff(.remote(hostID, path)):
                RemoteDiffView(hostID: hostID, path: path)
            case nil:
                emptyContent
            }
        } header: {
            EditorTabBarView(tabFocus: tabFocus, editorID: editorID) { location in
                if store.selectedTab == .file(location), store.markdownPreviews.contains(location) {
                    let editor = currentEditor
                    editor?.savePosition()
                    store.setMarkdownPreviewVisible(false, for: location)
                    DispatchQueue.main.async {
                        guard let editor, let window = editor.window, !editor.isHiddenOrHasHiddenAncestor else { return }
                        window.makeFirstResponder(editor)
                    }
                } else {
                    files.openMarkdownPreview(location, hosts: hosts, connections: connections, servers: servers)
                }
            }
            if let message = store.local.watchError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .focusedSceneValue(\.toggleFileDiff, fileDiffAction)
        .onReceive(files.$activeEditor) { nextStore in
            guard nextStore !== store, activity?.isActive.value ?? isActive else { return }
            focusRequest = UUID()
            currentEditor?.savePosition(includingUnfocused: true)
        }
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(isActive).eraseToAnyPublisher()) { active in
            guard active != wasActive else { return }
            wasActive = active
            if active {
                if let window = tabFocus.view?.window, let responder = window.firstResponder as? NSView,
                   !responder.isHiddenOrHasHiddenAncestor, !tabFocus.contains(window) { return }
                restoreEditorFocus()
            }
            else {
                focusRequest = UUID()
                currentEditor?.savePosition(includingUnfocused: true)
            }
        }
        .onChange(of: ObjectIdentifier(store)) { _, _ in restoreEditorFocus() }
        .onChange(of: currentDocumentID) { _, _ in
            guard let window = tabFocus.view?.window, tabFocus.contains(window) else { return }
            restoreEditorFocus()
        }
    }

    private var emptyContent: some View {
        Text("Select a file")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentDocumentID: ObjectIdentifier? {
        guard case let .file(location) = store.selectedTab else { return nil }
        return store.file(for: location).map(ObjectIdentifier.init)
    }

    private var fileDiffAction: (() -> Void)? {
        guard isActive else { return nil }
        return toggleFileDiff
    }

    private func toggleFileDiff() {
        guard activity?.isActive.value ?? isActive, files.explorer.nameEdit == nil,
              NSApp.keyWindow?.attachedSheet == nil else { return }
        switch store.selectedTab {
        case let .file(location):
            files.openDiff(location)
        case let .diff(location):
            files.open(location, hosts: hosts, connections: connections, servers: servers)
        case nil:
            break
        }
    }

    private var currentEditor: CodeTextView? {
        guard case let .file(location) = store.selectedTab else { return nil }
        return store.file(for: location)?.editorViews.views[editorID]?.documentView as? CodeTextView
    }

    private func restoreEditorFocus() {
        let request = UUID()
        focusRequest = request
        guard activity?.isActive.value ?? isActive else { return }
        let tab = store.selectedTab
        let responder = tabFocus.view?.window?.firstResponder
        DispatchQueue.main.async {
            guard focusRequest == request, activity?.isActive.value ?? isActive,
                  files.activeEditor === store, store.selectedTab == tab,
                  let view = tabFocus.view, !view.isHiddenOrHasHiddenAncestor, let window = view.window,
                  window.isKeyWindow, window.attachedSheet == nil,
                  window.firstResponder === responder || window.firstResponder === window || window.firstResponder == nil
            else { return }
            let editor = currentEditor
            if let editor, explorerFocus?.inheritEditorPosition(editor) == true {
                editor.restorePosition()
            }
            guard explorerFocus?.containsExplorer(window) != true else { return }
            // A project change must not take focus from the other Workspace pane.
            if explorerFocus?.content.contains(window) == true, !tabFocus.contains(window) { return }
            if let editor, editor.window === window, !editor.isHiddenOrHasHiddenAncestor {
                if window.makeFirstResponder(editor) { editor.restorePosition() }
            } else {
                tabFocus.activate()
            }
        }
    }
}

struct MarkdownSplitView<Content: View>: View {
    let source: String
    let showsPreview: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HSplitView {
            content.frame(minWidth: 180)
            if showsPreview {
                MarkdownView(source: source)
                    .frame(minWidth: 180)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

struct FilesCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard NSApp.keyWindow?.firstResponder is CodeTextView else { return }
                NSApp.sendAction(#selector(CodeTextView.saveDocument(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                guard NSApp.keyWindow?.firstResponder is CodeTextView else { return }
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
