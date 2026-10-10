import SwiftUI

struct CodexErrorView: View {
    let message: String

    var body: some View {
        DisclosureGroup {
            Text(message).textSelection(.enabled).font(.callout)
        } label: {
            Label(String(message.prefix(160)), systemImage: "exclamationmark.triangle")
                .lineLimit(2)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 24).padding(.vertical, 8)
    }
}
