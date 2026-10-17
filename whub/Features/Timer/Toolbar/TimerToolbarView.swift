import SwiftUI

struct TimerToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                TimerToolbarControlsView()
                ActivityTimelineBarView()
            }
        }
    }
}
