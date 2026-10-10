import SwiftUI

struct TimerView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                TimerControlsView()
                    .frame(width: 400)
                TimerClockView()
                    .frame(width: 560)
            }
            ActivityGraphView()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
