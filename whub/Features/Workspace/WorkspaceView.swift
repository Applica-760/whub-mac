import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var terminalStore: TerminalStore
    @State private var activePane: Pane = .terminal

    private enum Pane { case file, terminal }

    var body: some View {
        HSplitView {
            FileViewerView(closeShortcutEnabled: activePane == .file)
                .frame(minWidth: 300)
                .simultaneousGesture(TapGesture().onEnded { activePane = .file })
            TerminalView(closeShortcutEnabled: activePane == .terminal)
                .frame(minWidth: 300)
                .simultaneousGesture(TapGesture().onEnded { activePane = .terminal })
        }
        .onAppear {
            activePane = .terminal
            DispatchQueue.main.async {
                let terminal = terminalStore.selectedSession.terminal
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }
}
