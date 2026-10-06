import SwiftUI

struct TimerToolbarView: View {
    var body: some View {
        HStack(spacing: 6) {
            TimerToolbarControlsView()
            ActivityTimelineBarView()
        }
    }
}
