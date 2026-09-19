import SwiftUI
import WebKit

struct BrowserView: View {
    @State private var page = WebPage()
    @State private var address = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") {
                        if let item = page.backForwardList.backList.last {
                            page.load(item)
                        }
                    }
                    .disabled(page.backForwardList.backList.isEmpty)

                    Button("Forward", systemImage: "chevron.right") {
                        if let item = page.backForwardList.forwardList.first {
                            page.load(item)
                        }
                    }
                    .disabled(page.backForwardList.forwardList.isEmpty)

                    Button("Reload", systemImage: "arrow.clockwise") {
                        page.reload()
                    }
                    .disabled(page.url == nil)
                }
                .labelStyle(.iconOnly)

                TextField("URL", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(loadAddress)

                Button("Go", systemImage: "arrow.right", action: loadAddress)
                    .labelStyle(.iconOnly)
                    .disabled(browserURL == nil)
            }

            WidgetFrame {
                WebView(page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .navigationTitle("Browser")
        .onChange(of: page.url) { _, url in
            if let url {
                address = url.absoluteString
            }
        }
    }

    private var browserURL: URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let url = URL(string: value.contains("://") ? value : "https://\(value)")
        guard let url,
              url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }

    private func loadAddress() {
        guard let url = browserURL else { return }
        address = url.absoluteString
        page.load(url)
    }
}
