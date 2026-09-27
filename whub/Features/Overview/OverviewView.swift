import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TodoWidget()
                TimerView()
            }
            .padding()
        }
        .navigationTitle("Overview")
    }
}
