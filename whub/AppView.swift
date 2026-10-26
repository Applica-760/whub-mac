import SwiftUI

struct AppView: View {
    @EnvironmentObject private var browser: BrowserStore
    @FocusedValue(\.workspaceActions) private var workspaceActions
    @Binding var section: WorkspaceSection
    @State private var explorerFocus = ExplorerFocusNavigation()

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar(onFileSelect: {
                section = .editor
            }, onOpenInBrowser: openInBrowser,
                            focus: explorerFocus)
        } detail: {
            WorkspaceView(section: $section) { panes in
                RetainedPageContainer(selection: true, focus: explorerFocus.content) { _ in
                    panes
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

    private func openInBrowser(_ url: URL) {
        browser.open(url)
        section = .browser
    }
}
