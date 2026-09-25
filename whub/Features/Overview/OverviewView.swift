import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var terminalStore: TerminalStore

    var body: some View {
        ScrollView {
            TerminalWidget(session: terminalStore.selectedSession)
                .padding()
        }
        .navigationTitle("Overview")
    }
}
