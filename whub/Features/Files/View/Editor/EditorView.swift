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
            if case let .diff(location) = store.selectedTab, let url = location.localURL,
               let state = store.local.diffStores[url] {
                DiffContent(state: state).id(location)
            } else if case let .diff(location) = store.selectedTab, case .remote = location,
                      let root = files.explorer.selectedLocation, let git = files.remoteGitStores[root] {
                RemoteDiffContent(git: git, location: location).id(location)
            } else if case let .file(location) = store.selectedTab, let state = store.local.fileStores[location] {
                FileContent(state: state, editorID: editorID, refreshID: files.refreshID,
                            showsMarkdownPreview: store.markdownPreviews.contains(location)) { [weak store] in
                    if store?.previewTab == .file(location) { store?.open(.file(location)) }
                }
                .id(location)
            } else if case let .file(location) = store.selectedTab, case .remote = location {
                RemoteViewerView(store: store.remote, git: files.explorer.selectedLocation.flatMap { files.remoteGitStores[$0] },
                                 location: location, editorID: editorID, showsMarkdownPreview: store.markdownPreviews.contains(location))
                    .id(location)
            } else {
                Text("Select a file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } header: {
            HStack(spacing: 8) {
                EditorTabBarView(tabFocus: tabFocus, editorID: editorID)
                if let location = store.markdownPreviewLocation {
                    let visible = store.markdownPreviews.contains(location)
                    Button(visible ? "Hide Preview" : "Show Preview", systemImage: "rectangle.split.2x1") {
                        let editor = currentEditor
                        editor?.savePosition()
                        store.setMarkdownPreviewVisible(!visible, for: location)
                        DispatchQueue.main.async {
                            guard let editor, let window = editor.window, !editor.isHiddenOrHasHiddenAncestor else { return }
                            window.makeFirstResponder(editor)
                        }
                    }
                    .accessibilityIdentifier("markdown.preview.toggle")
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!isActive)
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
            if active { restoreEditorFocus() }
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

private struct FileContent: View {
    @ObservedObject var state: LocalFileStore
    let editorID: String
    let refreshID: Int
    let showsMarkdownPreview: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.diskMessage {
                Text(message)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
            fileContent
        }
    }

    @ViewBuilder private var fileContent: some View {
        switch state.document.content {
        case let .text(source):
            MarkdownSplitView(source: source, showsPreview: showsMarkdownPreview) {
                LocalCodeEditorView(fileURL: state.fileURL, source: source, refreshID: refreshID,
                                    state: state, editorID: editorID, onEdit: onEdit)
            }
        case .binary:
            BinaryView(fileURL: state.fileURL)
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
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
