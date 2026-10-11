import AppKit
import LinkPresentation
import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        @Bindable var session = store.selectedSession

        WidgetFrame {
            RetainedBrowserSessions(sessions: store.sessions, selection: store.selectedSessionID)
        } header: {
            TabBarContainer(
                ids: store.sessions.map(\.id),
                selection: store.selectedSessionID,
                select: { id in
                    tabFocus.activate()
                    store.select(id)
                },
                close: { id in
                    tabFocus.activate()
                    store.remove(id)
                },
                canClose: { _ in store.sessions.count > 1 },
                move: store.move,
                isShortcutTarget: tabFocus.contains
            ) { id, isSelected, actions in
                if let session = store.sessions.first(where: { $0.id == id }) {
                    TabBar(
                        title: session.title,
                        icon: Image(systemName: "globe"),
                        isSelected: isSelected,
                        isCloseDisabled: store.sessions.count == 1,
                        action: actions.select,
                        closeAction: actions.close
                    )
                }
            }

            HStack {
                ControlGroup {
                    Button("Bookmarks", systemImage: "house") {
                        session.showsBookmarks = true
                    }

                    Button("Back", systemImage: "chevron.left") {
                        if let item = session.page.backForwardList.backList.last {
                            session.page.load(item)
                            session.showsBookmarks = false
                        }
                    }
                    .disabled(session.page.backForwardList.backList.isEmpty)

                    Button("Forward", systemImage: "chevron.right") {
                        if let item = session.page.backForwardList.forwardList.first {
                            session.page.load(item)
                            session.showsBookmarks = false
                        }
                    }
                    .disabled(session.page.backForwardList.forwardList.isEmpty)

                    Button("Reload", systemImage: "arrow.clockwise") {
                        session.page.reload()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session.page.url == nil)
                }
                .labelStyle(.iconOnly)

                TextField("URL", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(session.loadAddress)
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .navigationTitle("Browser")
        .onAppear {
            if isActive { DispatchQueue.main.async { tabFocus.activate() } }
        }
        .onChange(of: store.selectedSessionID) { _, _ in
            if isActive { tabFocus.activate() }
        }
        .onChange(of: isActive) { _, active in
            if active { tabFocus.activate() }
        }
    }
}

private struct RetainedBrowserSessions: NSViewRepresentable {
    let sessions: [BrowserSession]
    let selection: BrowserSession.ID
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let ids = Set(sessions.map(\.id))
        for id in Array(coordinator.pages.keys) where !ids.contains(id) {
            guard let page = coordinator.pages.removeValue(forKey: id) else { continue }
            resignFocus(in: page)
            page.removeFromSuperview()
        }
        for session in sessions {
            if coordinator.pages[session.id] == nil, session.id == selection {
                let page = NSHostingView(rootView: AnyView(BrowserSessionView(session: session).environment(\.self, environment)))
                page.sizingOptions = []
                page.frame = container.bounds
                page.autoresizingMask = [.width, .height]
                page.isHidden = true
                container.addSubview(page)
                coordinator.pages[session.id] = page
            }
            guard let page = coordinator.pages[session.id] else { continue }
            let selected = session.id == selection
            if !selected { resignFocus(in: page) }
            page.isHidden = !selected
            page.setAccessibilityHidden(!selected)
            page.rootView = AnyView(BrowserSessionView(session: session).environment(\.self, environment))
        }
        assert(Set(coordinator.pages.keys).isSubset(of: ids))
        assert(coordinator.pages.values.filter { !$0.isHidden }.count == 1)
    }

    private func resignFocus(in page: NSView) {
        if let responder = page.window?.firstResponder as? NSView,
           responder.isDescendant(of: page) {
            page.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator {
        var pages: [BrowserSession.ID: NSHostingView<AnyView>] = [:]
    }
}

private struct BrowserSessionView: View {
    let session: BrowserSession
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData

    var body: some View {
        Group {
            if session.showsBookmarks {
                GeometryReader { geometry in
                    ScrollView {
                        Grid(horizontalSpacing: 24, verticalSpacing: 24) {
                            ForEach(bookmarkRows.indices, id: \.self) { row in
                                GridRow {
                                    ForEach(bookmarkRows[row]) { bookmark in
                                        BookmarkButton(bookmark: bookmark) {
                                            session.address = bookmark.url.absoluteString
                                            session.loadAddress()
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
                WebView(session.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: session.page.url) { _, url in
            if let url {
                session.address = url.absoluteString
            }
        }
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
