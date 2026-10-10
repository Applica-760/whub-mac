import SwiftUI

struct WidgetFrame<Content: View, Header: View>: View {
    private let content: Content
    private let header: Header

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.content = content()
        self.header = header()
    }

    init(@ViewBuilder content: () -> Content) where Header == EmptyView {
        self.init(content: content, header: { EmptyView() })
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(spacing: 8) {
            header
            content
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                .background {
                    Color.clear
                        .glassEffect(.regular, in: shape)
                        .allowsHitTesting(false)
                }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 8)
    }
}
