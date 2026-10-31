import SwiftUI

struct AppView: View {
    @EnvironmentObject private var files: FilesStore
    @FocusedValue(\.workspaceActions) private var workspaceActions
    @Binding var section: WorkspaceSection
    @State private var explorerFocus = ExplorerFocusNavigation()

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar(onFileSelect: {
                section = .editor
            }, focus: explorerFocus)
        } detail: {
            WorkspaceView(section: $section) { panes in
                RetainedPageContainer(selection: true, focus: explorerFocus.content) { _ in
                    panes
                        .environmentObject(files.activeEditor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(section.label)
        .environment(\.explorerFocusNavigation, explorerFocus)
        .focusedSceneValue(\.toggleExplorerFocus, { explorerFocus.toggle(prefersEditor: section == .editor) })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 550)
        .toolbar {
            WorkspaceToolbar(selection: workspaceActions?.selection ?? $section)
            RemoteConnectionToolbar()
            SettingsToolbar()
        }
    }
}
