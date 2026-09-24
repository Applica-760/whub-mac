import LinkPresentation
import SwiftUI
import WebKit

private let githubBookmarkTitle = "GitHub"
private let githubBookmarkURL = URL(string: "https://github.com/Applica-760")!

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var showsBookmarks = true
    @State private var githubIcon: Image?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ControlGroup {
                    Button("Bookmarks", systemImage: "house") {
                        showsBookmarks = true
                    }

                    Button("Back", systemImage: "chevron.left") {
                        if let item = store.page.backForwardList.backList.last {
                            store.page.load(item)
                            showsBookmarks = false
                        }
                    }
                    .disabled(store.page.backForwardList.backList.isEmpty)

                    Button("Forward", systemImage: "chevron.right") {
                        if let item = store.page.backForwardList.forwardList.first {
                            store.page.load(item)
                            showsBookmarks = false
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
                    .onSubmit(loadAddress)

                Button("Go", systemImage: "arrow.right", action: loadAddress)
                    .labelStyle(.iconOnly)
                    .disabled(store.browserURL == nil)
            }

            WidgetFrame {
                if showsBookmarks {
                    Button {
                        store.address = githubBookmarkURL.absoluteString
                        loadAddress()
                    } label: {
                        VStack(spacing: 8) {
                            Group {
                                if let githubIcon {
                                    githubIcon.resizable().scaledToFit()
                                } else {
                                    Image(systemName: "globe").resizable().scaledToFit()
                                }
                            }
                            .frame(width: 72, height: 72)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            Text(githubBookmarkTitle)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        guard githubIcon == nil,
                              let metadata = try? await LinkMetadata(fetching: githubBookmarkURL, timeout: .seconds(30))
                        else { return }
                        githubIcon = try? await metadata.media(.icon, as: Image.self)
                    }
                } else {
                    WebView(store.page)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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

    private func loadAddress() {
        guard store.browserURL != nil else { return }
        store.loadAddress()
        showsBookmarks = false
    }
}
