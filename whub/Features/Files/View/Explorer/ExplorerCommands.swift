import SwiftUI

struct FilesNavigationMenu: View {
    @ObservedObject var store: FilesStore
    @FocusedValue(\.explorerPulldownSelection) private var explorerPulldownSelection
    @FocusedValue(\.toggleExplorerFocus) private var toggleExplorerFocus
    @FocusedValue(\.toggleExplorerDiff) private var toggleExplorerDiff

    var body: some View {
        Button("Toggle Diff Explorer") { toggleExplorerDiff?() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(toggleExplorerDiff == nil || store.explorer.selectedLocation == nil || store.explorer.nameEdit != nil)
        Button("Focus Explorer or Feature") { toggleExplorerFocus?() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(toggleExplorerFocus == nil || store.explorer.nameEdit != nil)
        Button("Reload Files") { store.refresh() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Previous Project or Worktree") { explorerPulldownSelection?.move(by: -1) }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(explorerPulldownSelection == nil)
        Button("Next Project or Worktree") { explorerPulldownSelection?.move(by: 1) }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(explorerPulldownSelection == nil)
    }
}
