import SwiftUI

struct AppView: View {
    enum Section: CaseIterable, Hashable {
        case file
        case agentBook
        case browser
        case terminal
        case overview
        case motion

        var label: String {
            switch self {
            case .file: "File"
            case .terminal: "Terminal"
            case .browser: "Browser"
            case .agentBook: "AgentBook"
            case .overview: "Overview"
            case .motion: "Motion"
            }
        }

        var systemImage: String {
            switch self {
            case .file: "doc.text"
            case .terminal: "terminal"
            case .browser: "globe"
            case .agentBook: "book"
            case .overview: "rectangle.3.group"
            case .motion: "hand.draw"
            }
        }

        @ViewBuilder
        func content(agentBook: AgentBookStore) -> some View {
            switch self {
            case .overview: OverviewView()
            case .file: EditorView()
            case .terminal: TerminalView()
            case .browser: BrowserView()
            case .agentBook: AgentBookView(store: agentBook)
            case .motion: MotionView()
            }
        }
    }

    @EnvironmentObject private var browser: BrowserStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @Binding var section: Section
    @State private var explorerFocus = ExplorerFocusNavigation()

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar(onFileSelect: { section = .file }, onOpenInBrowser: openInBrowser,
                            focus: explorerFocus)
        } detail: {
            RetainedPageContainer(selection: section, focus: explorerFocus.content) { page in
                page.content(agentBook: agentBook)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(section.label)
        .environment(\.explorerFocusNavigation, explorerFocus)
        .focusedSceneValue(\.toggleExplorerFocus, { explorerFocus.toggle(prefersEditor: section == .file) })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .toolbar {
            AgentBookToolbar { section = .agentBook }
            TimerToolbar()
            RemoteConnectionToolbar()
            FeatureToolbar(selection: $section)
            SettingsToolbar()
        }
    }

    private func openInBrowser(_ url: URL) {
        browser.open(url)
        section = .browser
    }
}

private struct FeatureToolbar: ToolbarContent {
    @Binding var selection: AppView.Section

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("ページ", selection: $selection) {
                ForEach(AppView.Section.allCases, id: \.self) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
