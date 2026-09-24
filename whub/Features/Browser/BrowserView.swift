import LinkPresentation
import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var store: BrowserStore
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData
    @State private var showsBookmarks = true

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
                    GeometryReader { geometry in
                        ScrollView {
                            Grid(horizontalSpacing: 24, verticalSpacing: 24) {
                                ForEach(bookmarkRows.indices, id: \.self) { row in
                                    GridRow {
                                        ForEach(bookmarkRows[row]) { bookmark in
                                            BookmarkButton(bookmark: bookmark) {
                                                store.address = bookmark.url.absoluteString
                                                loadAddress()
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        }
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

    private var bookmarks: [Bookmark] {
        (try? BookmarkStorage.decode(bookmarkData)) ?? []
    }

    private var bookmarkRows: [[Bookmark]] {
        stride(from: 0, to: bookmarks.count, by: 5).map { start in
            Array(bookmarks[start..<min(start + 5, bookmarks.count)])
        }
    }
}

private struct BookmarkButton: View {
    let bookmark: Bookmark
    let action: () -> Void
    @State private var icon: Image?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Group {
                    if let icon {
                        icon.resizable().scaledToFit()
                    } else {
                        Image(systemName: "globe").resizable().scaledToFit()
                    }
                }
                .frame(width: 72, height: 72)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(bookmark.title)
                    .lineLimit(1)
                    .frame(width: 88)
            }
        }
        .buttonStyle(.plain)
        .task(id: bookmark.url) {
            icon = nil
            guard let metadata = try? await LinkMetadata(fetching: bookmark.url, timeout: .seconds(30))
            else { return }
            icon = try? await metadata.media(.icon, as: Image.self)
        }
    }
}
