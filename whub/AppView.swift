import SwiftUI

struct AppView: View {
    enum Section: CaseIterable, Hashable {
        case workspace
        case browser
        case overview
        case motion

        var label: String {
            switch self {
            case .workspace: "Workspace"
            case .browser: "Browser"
            case .overview: "Overview"
            case .motion: "Motion"
            }
        }

        var systemImage: String {
            switch self {
            case .workspace: "chevron.left.forwardslash.chevron.right"
            case .browser: "globe"
            case .overview: "rectangle.3.group"
            case .motion: "hand.draw"
            }
        }

        @ViewBuilder
        func content() -> some View {
            switch self {
            case .overview: OverviewView()
            case .workspace: WorkspaceView()
            case .browser: BrowserView()
            case .motion: MotionView()
            }
        }
    }

    @Binding var section: Section
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            FileExplorerView { section = .workspace }
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
