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

    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var browser: BrowserStore
    @EnvironmentObject private var agentBook: AgentBookStore
    @Binding var section: Section
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            ExplorerView(onFileSelect: {
                section = .file
            }, onOpenInBrowser: { url in
                browser.open(url)
                section = .browser
            }, store: files.explorer)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 640)
        } detail: {
            RetainedPageContainer(selection: section) { page in
                page.content(agentBook: agentBook)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(section.label)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AgentBookToolbarView(store: agentBook) {
                    section = .agentBook
                }
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                TimerToolbarView()
            }

            ToolbarItem(placement: .primaryAction) {
                featurePicker
            }

            ToolbarItem(placement: .primaryAction) {
                settingsButton
            }
        }
    }

    private var featurePicker: some View {
        Picker("ページ", selection: $section) {
            ForEach(Section.allCases, id: \.self) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
    }
}
