import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ControlGroup {
                    Button("Back", systemImage: "chevron.left") {
                        if let item = store.page.backForwardList.backList.last {
                            store.page.load(item)
                        }
                    }
                    .disabled(store.page.backForwardList.backList.isEmpty)

                    Button("Forward", systemImage: "chevron.right") {
                        if let item = store.page.backForwardList.forwardList.first {
                            store.page.load(item)
                        }
                    }
                    .disabled(store.page.backForwardList.forwardList.isEmpty)

                    Button("Reload", systemImage: "arrow.clockwise") {
                        store.page.reload()
                    }
                    .disabled(store.page.url == nil)
                }
                .labelStyle(.iconOnly)

                TextField("URL", text: $store.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(store.loadAddress)

                Button("Go", systemImage: "arrow.right", action: store.loadAddress)
                    .labelStyle(.iconOnly)
                    .disabled(store.browserURL == nil)
            }

            WidgetFrame {
                WebView(store.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .navigationTitle("Browser")
        .onChange(of: store.page.url) { _, url in
            if let url {
                store.address = url.absoluteString
            }
        }
    }
}
