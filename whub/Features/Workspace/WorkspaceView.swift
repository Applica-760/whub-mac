import SwiftUI

struct WorkspaceView: View {
    @State private var activePane: Pane = .file

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
    }
}
