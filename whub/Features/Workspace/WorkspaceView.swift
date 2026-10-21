import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var agentBook: AgentBookStore

    var body: some View {
        HSplitView {
            EditorView()
                .frame(minWidth: 300)
            AgentBookView(store: agentBook)
                .frame(minWidth: 700)
        }
    }
}
