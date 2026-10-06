import SwiftUI

struct TimerView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            TimerControlsView()
                .frame(width: 400)
            TimerClockView()
                .frame(width: 560)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
