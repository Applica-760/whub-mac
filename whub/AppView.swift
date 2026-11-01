import AppKit
import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var openEditor: @MainActor () -> Void = {}
}

struct AppView: View {
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @Environment(\.modelContext) private var context
    @State private var selectedPage = FeaturePage.editor
    @State private var explorerFocus = ExplorerFocusNavigation()
    @State private var contentFocus = TabPaneFocus()
    @State private var agentBookFocus = TabPaneFocus()
    @State private var showsAgentBook = true

    var body: some View {
        let selection = Binding(get: { selectedPage }, set: selectPage)

        NavigationSplitView {
            ExplorerView(onFileSelect: {
                selectedPage = .editor
            }, store: files.explorer, focus: explorerFocus)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 640)
        } detail: {
            RetainedPageContainer(selection: selectedPage, focus: explorerFocus.content) { page in
                page.content(context: context).environmentObject(files.activeEditor)
            }
            .background(TabPaneFocusView(focus: contentFocus, activatesOnClick: false))
            .inspector(isPresented: $showsAgentBook) {
                AgentBookView(store: agentBook)
                    .environment(\.openEditor, { selectPage(.editor) })
                    .background(TabPaneFocusView(focus: agentBookFocus, activatesOnClick: false))
                    .inspectorColumnWidth(min: 500, ideal: 600, max: 1200)
            }
            .toolbar {
                AppToolbar(selection: selection, showsAgentBook: $showsAgentBook)
            }
        }
        .focusedSceneValue(\.featureActions, FeatureActions(
            selection: selection,
            toggleAgentBook: { showsAgentBook.toggle() },
            targetsAgentBook: {
                guard let window = NSApp.keyWindow else { return false }
                return agentBookFocus.contains(window)
            }
        ))
        .navigationTitle(selectedPage.label)
        .environment(\.explorerFocusNavigation, explorerFocus)
        .focusedSceneValue(\.toggleExplorerFocus, { explorerFocus.toggle(prefersEditor: selectedPage == .editor) })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
    }

    private func selectPage(_ next: FeaturePage) {
        contentFocus.activate()
        selectedPage = next
    }
}

enum FeaturePage: CaseIterable, Hashable {
    case editor, terminal, overview

    @ViewBuilder func content(context: ModelContext) -> some View {
        switch self {
        case .editor: EditorView()
        case .terminal: TerminalView(context: context)
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
        let pages = Self.allCases
        let index = pages.firstIndex(of: self)!
        return pages[((index + offset) % pages.count + pages.count) % pages.count]
    }
}
