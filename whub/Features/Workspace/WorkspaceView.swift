import SwiftUI

struct WorkspaceView: View {
    var body: some View {
        HSplitView {
            EditorView()
                .frame(minWidth: 300)
            TerminalView()
                .frame(minWidth: 300)
        }
        .navigationTitle("Workspace")
    }
}
