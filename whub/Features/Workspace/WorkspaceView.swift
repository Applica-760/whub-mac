import SwiftUI

struct WorkspaceView: View {
    var body: some View {
        HSplitView {
            FileViewerView(closeShortcutEnabled: false)
                .frame(minWidth: 300)
            TerminalView(closeShortcutEnabled: false)
                .frame(minWidth: 300)
        }
    }
}
