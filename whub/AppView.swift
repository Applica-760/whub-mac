import SwiftUI

struct AppView: View {
    enum Section: CaseIterable, Hashable {
        case workspace
        case file
        case terminal
        case browser
        case codex
        case overview
        case motion

        var label: String {
            switch self {
            case .workspace: "Workspace"
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
            case .workspace: "chevron.left.forwardslash.chevron.right"
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
            case .workspace: WorkspaceView()
            case .file: FileViewerView().navigationTitle("File")
            case .terminal: TerminalView().navigationTitle("Terminal")
            case .browser: BrowserView()
            case .codex: CodexView()
            case .motion: MotionView()
            }
        }
    }

    @EnvironmentObject private var files: FilesStore
    @Binding var section: Section
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            ExplorerView(onFileSelect: {
                section = .file
            }, store: files.explorer)
                .navigationSplitViewColumnWidth(min: 200, ideal: 320, max: 640)
        } detail: {
            section.content()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .toolbar {
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
