import SwiftUI

struct WidgetFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        content
            .frame(maxWidth: .infinity)
            .clipShape(shape)
            .background {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .allowsHitTesting(false)
            }
    }
}
