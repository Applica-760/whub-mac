import AppKit
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var terminalStore: TerminalStore

    var body: some View {
        HSplitView {
            FileViewerView()
                .frame(minWidth: 300)
            TerminalView()
                .frame(minWidth: 300)
        }
        .onAppear {
            DispatchQueue.main.async {
                let terminal = terminalStore.selectedSession.terminal
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }
}
