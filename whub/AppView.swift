import AppKit
import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var openEditor: @MainActor () -> Void = {}
}

struct AppView: View {
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var browser: BrowserStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @Environment(\.modelContext) private var context
    @State private var selectedPage = FeaturePage.editor
    @State private var explorerFocus = ExplorerFocusNavigation()
    @State private var contentFocus = TabPaneFocus()
    @State private var agentBookFocus = TabPaneFocus()
    @State private var terminal: TerminalStore?
    @State private var showsTerminal = false
    @State private var showsAgentBook = true

    var body: some View {
        let selection = Binding(get: { selectedPage }, set: selectPage)

        NavigationSplitView {
            ExplorerView(onFileSelect: {
                selectedPage = .editor
            }, onOpenIssues: { url in
                browser.openIssues(url)
                selectPage(.browser)
            }, store: files.explorer, focus: explorerFocus)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 640)
        } detail: {
            VSplitView {
                RetainedPageContainer(selection: selectedPage, focus: explorerFocus.content) { page in
                    page.content(context: context)
                }
                .frame(minHeight: 100)
                if showsTerminal, let store = terminal {
                    TerminalView(store: store)
                        .frame(minHeight: 150)
                        .background(TabPaneFocusView(focus: store.panelFocus, activatesOnClick: false))
                }
            }
            .environmentObject(files.activeEditor)
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
            toggleTerminal: {
                if terminal == nil { terminal = TerminalStore(context: context) }
                if let terminal { showsTerminal = terminal.togglePanel(isVisible: showsTerminal) }
            },
            toggleAgentBook: { showsAgentBook.toggle() },
            targetsAgentBook: {
                guard let window = NSApp.keyWindow else { return false }
                return agentBookFocus.contains(window)
            }
        ))
        .navigationTitle("")
        .environment(\.explorerFocusNavigation, explorerFocus)
        .focusedSceneValue(\.toggleExplorerFocus, { explorerFocus.toggle(prefersEditor: selectedPage == .editor) })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .modifier(WindowVisibility())
    }

    private func selectPage(_ next: FeaturePage) {
        contentFocus.activate()
        selectedPage = next
    }
}

enum FeaturePage: CaseIterable, Hashable {
    case editor, browser, overview

    @ViewBuilder func content(context: ModelContext) -> some View {
        switch self {
        case .editor: EditorView()
        case .browser: BrowserView()
        case .overview: OverviewView()
        }
    }

    var label: String {
        switch self {
        case .editor: "Editor"
        case .browser: "Browser"
        case .overview: "Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "doc.text"
        case .browser: "globe"
        case .overview: "rectangle.3.group"
        }
    }

    func moved(by offset: Int) -> Self {
        let pages = Self.allCases
        let index = pages.firstIndex(of: self)!
        return pages[((index + offset) % pages.count + pages.count) % pages.count]
    }
}
