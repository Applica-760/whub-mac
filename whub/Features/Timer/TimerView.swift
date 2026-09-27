import SwiftUI

struct TimerView: View {
    var body: some View {
        WidgetFrame {
            ContentUnavailableView(
                "Timer",
                systemImage: "timer",
                description: Text("Time tracking will be available here.")
            )
        }
    }
}
