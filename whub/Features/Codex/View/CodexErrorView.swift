import SwiftUI

struct CodexErrorView: View {
    let message: String

    var body: some View {
        DisclosureGroup {
            ScrollView {
                Text(message).textSelection(.enabled).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Label(String(message.prefix(160)), systemImage: "exclamationmark.triangle")
                .lineLimit(2)
        }
        .foregroundStyle(.red)
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 420)
    }
}
