import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TodoWidget()
                TimerView()
            }
        }
    }
}
