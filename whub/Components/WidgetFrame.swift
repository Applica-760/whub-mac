import SwiftUI

struct WidgetFrame<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
        }
    }
}
