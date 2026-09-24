import SwiftUI

struct AppView: View {
    enum Section: CaseIterable, Hashable {
        case overview
        case file
        case workspace
        case browser
        case terminal
        case todo
        case vault
        case status
        case timer
        case motion

        var label: String {
            switch self {
            case .overview: "Overview"
            case .file: "File"
            case .workspace: "Workspace"
            case .browser: "Browser"
            case .status: "Status"
            case .timer: "Timer"
            case .vault: "Vault"
            case .terminal: "Terminal"
            case .todo: "Todo"
            case .motion: "Motion"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "rectangle.3.group"
            case .file: "doc.text"
            case .workspace: "keyboard"
            case .browser: "globe"
            case .status: "tablecells"
            case .timer: "timer"
            case .vault: "tray.full"
            case .terminal: "terminal"
            case .todo: "list.bullet.clipboard"
            case .motion: "hand.draw"
            }
        }

        @ViewBuilder
        func content() -> some View {
            switch self {
            case .overview: OverviewView()
            case .file: FileViewerView()
            case .workspace: WorkspaceView()
            case .browser: BrowserView()
            case .status: StatusView()
            case .timer: TimerView()
            case .vault: VaultExplorerView()
            case .terminal: TerminalView()
            case .todo: TodoView()
            case .motion: MotionView()
            }
        }
    }

    @Binding var section: Section
    @EnvironmentObject private var fileViewerStore: FileViewerStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            FileExplorerView { fileURL in
                fileViewerStore.open(fileURL)
                if section != .workspace {
                    section = .file
                }
            }
                .navigationSplitViewColumnWidth(min: 200, ideal: 320, max: 640)
        } detail: {
            section.content()
        }
        .frame(minWidth: 950, minHeight: 550)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
