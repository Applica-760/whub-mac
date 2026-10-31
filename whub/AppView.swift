import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var openWorkspaceEditor: @MainActor () -> Void = {}
}

struct AppView: View {
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @EnvironmentObject private var terminal: TerminalStore
    @Binding var section: FeaturePage
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
            RetainedPageContainer(selection: section, focus: explorerFocus.content) { page in
                page.content.environmentObject(files.activeEditor)
            }
            .background(TabPaneFocusView(focus: leftFocus, activatesOnClick: false))
            .inspector(isPresented: $showsAgentBook) {
                AgentBookView(store: agentBook)
                    .environment(\.openWorkspaceEditor, { selectSection(.editor) })
                    .background(TabPaneFocusView(focus: agentFocus, activatesOnClick: false))
                    .inspectorColumnWidth(min: 500, ideal: 600, max: 1200)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("ページ", selection: selection) {
                        ForEach(FeaturePage.allCases, id: \.self) { section in
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
        .focusedSceneValue(\.featureActions, FeatureActions(
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

    private func selectSection(_ next: FeaturePage) {
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

enum FeaturePage: CaseIterable, Hashable {
    case editor, terminal, overview

    @ViewBuilder var content: some View {
        switch self {
        case .editor: EditorView()
        case .terminal: TerminalView()
        case .overview: OverviewView()
        }
    }

    var label: String {
        switch self {
        case .editor: "Editor"
        case .terminal: "Terminal"
        case .overview: "Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "doc.text"
        case .terminal: "terminal"
        case .overview: "rectangle.3.group"
        }
    }

    func moved(by offset: Int) -> Self {
        let sections = Self.allCases
        let index = sections.firstIndex(of: self)!
        return sections[((index + offset) % sections.count + sections.count) % sections.count]
    }
}
