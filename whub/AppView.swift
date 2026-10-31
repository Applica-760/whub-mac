import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var openWorkspaceEditor: @MainActor () -> Void = {}
}

struct AppView: View {
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @EnvironmentObject private var terminal: TerminalStore
    @Binding var section: WorkspaceSection
    @State private var explorerFocus = ExplorerFocusNavigation()
    @State private var leftFocus = TabPaneFocus()
    @State private var agentFocus = TabPaneFocus()
    @State private var showsAgentBook = true

    var body: some View {
        let selection = Binding(get: { section }, set: selectSection)

        NavigationSplitView {
            ExplorerSidebar(onFileSelect: {
                section = .editor
            }, focus: explorerFocus)
        } detail: {
            RetainedPageContainer(selection: true, focus: explorerFocus.content) { _ in
                WorkspacePanes(section: section, leftFocus: leftFocus)
                    .environmentObject(files.activeEditor)
            }
            .inspector(isPresented: $showsAgentBook) {
                AgentBookView(store: agentBook)
                    .environment(\.openWorkspaceEditor, { selectSection(.editor) })
                    .background(TabPaneFocusView(focus: agentFocus, activatesOnClick: false))
                    .inspectorColumnWidth(min: 500, ideal: 600, max: 1200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("ページ", selection: selection) {
                        ForEach(WorkspaceSection.allCases, id: \.self) { section in
                            Label(section.label, systemImage: section.systemImage).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                RemoteConnectionToolbar()
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button("Toggle AgentBook", systemImage: "sidebar.right") {
                        showsAgentBook.toggle()
                    }
                }
            }
        }
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            selection: selection,
            toggleAgentBook: { showsAgentBook.toggle() },
            newTab: newTab,
            targetsAgentBook: {
                guard let window = NSApp.keyWindow else { return false }
                return agentFocus.contains(window)
            }
        ))
        .navigationTitle(section.label)
        .environment(\.explorerFocusNavigation, explorerFocus)
        .focusedSceneValue(\.toggleExplorerFocus, { explorerFocus.toggle(prefersEditor: section == .editor) })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
    }

    private func selectSection(_ next: WorkspaceSection) {
        leftFocus.activate()
        section = next
    }

    private func newTab() {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
        if agentFocus.contains(window) {
            agentBook.add()
        } else if leftFocus.contains(window) {
            switch section {
            case .terminal: terminal.add()
            case .editor, .overview: break
            }
        }
    }
}
