import SwiftUI

struct TimerView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                TimerControlsView()
                    .frame(width: 220)
                TimerCategoryView()
                    .frame(width: 220)
            }
            TimerClockView()
                .frame(width: 560)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
