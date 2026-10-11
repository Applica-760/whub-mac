import SwiftUI

struct AppView: View {
    enum Section: CaseIterable, Hashable {
        case file
        case terminal
        case browser
        case codex
        case overview
        case motion

        var label: String {
            switch self {
            case .file: "File"
            case .terminal: "Terminal"
            case .browser: "Browser"
            case .codex: "AgentBook"
            case .overview: "Overview"
            case .motion: "Motion"
            }
        }

        var systemImage: String {
            switch self {
            case .file: "doc.text"
            case .terminal: "terminal"
            case .browser: "globe"
            case .codex: "book"
            case .overview: "rectangle.3.group"
            case .motion: "hand.draw"
            }
        }

        @ViewBuilder
        func content() -> some View {
            switch self {
            case .overview: OverviewView()
            case .file: EditorView().navigationTitle("File")
            case .terminal: TerminalView().navigationTitle("Terminal")
            case .browser: BrowserView()
            case .codex: CodexView()
            case .motion: MotionView()
            }
        }
    }

    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var browser: BrowserStore
    @EnvironmentObject private var codex: CodexTabsStore
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
                page.content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(section.label)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CodexTabBar(sessions: codex.sessions, selection: codex.selectedSessionID,
                            completedSessionIDs: codex.completedSessionIDs) { id in
                    codex.select(id)
                    section = .codex
                }
                .frame(width: 156, height: 36)
                .padding(.horizontal, 6)
                .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                TimerToolbarView()

                Picker("ページ", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Label(section.label, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)

            }
        }
    }
}
