import AppKit
import LinkPresentation
import SwiftUI
import WebKit

struct BrowserView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @State private var tabFocus = TabPaneFocus()
    @State private var bookmarkFocusRequest: BrowserSession.ID?
    @State private var webFocusRequest = UUID()
    @FocusState private var focusedAddress: BrowserSession.ID?
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        @Bindable var session = store.selectedSession

        WidgetFrame {
            RetainedBrowserSessions(
                sessions: store.sessions, selection: store.selectedSessionID,
                webFocusRequest: webFocusRequest,
                bookmarkFocusRequest: $bookmarkFocusRequest,
                focusAddress: { focusedAddress = store.selectedSessionID }
            )
        } header: {
            TabBarContainer(
                ids: store.sessions.map(\.id),
                selection: store.selectedSessionID,
                select: { id in
                    store.select(id)
                    activateBrowser()
                },
                close: { id in
                    tabFocus.activate()
                    store.remove(id)
                },
                canClose: { _ in true },
                move: store.move,
                isShortcutTarget: tabFocus.contains
            ) { id, isSelected, actions in
                if let session = store.sessions.first(where: { $0.id == id }) {
                    TabBar(
                        title: session.title,
                        icon: Image(systemName: "globe"),
                        isSelected: isSelected,
                        width: 120,
                        action: actions.select,
                        closeAction: actions.close
                    )
                    .help(session.title)
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
                            activateBrowser()
                        }
                    }
                    .disabled(session.page.backForwardList.backList.isEmpty)

                    Button("Forward", systemImage: "chevron.right") {
                        if let item = session.page.backForwardList.forwardList.first {
                            session.page.load(item)
                            session.showsBookmarks = false
                            activateBrowser()
                        }
                    }
                    .disabled(session.page.backForwardList.forwardList.isEmpty)

                    Button("Reload", systemImage: "arrow.clockwise") {
                        session.page.reload()
                        activateBrowser()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(session.page.url == nil)
                }
                .labelStyle(.iconOnly)

                TextField("URL", text: $session.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedAddress, equals: session.id)
                    .onSubmit {
                        session.loadAddress()
                        activateBrowser()
                    }
                    .onKeyPress(.tab, phases: .down) { press in
                        guard press.modifiers.isEmpty, session.showsBookmarks else { return .ignored }
                        focusedAddress = nil
                        bookmarkFocusRequest = session.id
                        return .handled
                    }
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .onAppear {
            if isActive { DispatchQueue.main.async { activateBrowser() } }
        }
        .onChange(of: store.selectedSessionID) { _, _ in
            if isActive { activateBrowser() }
        }
        .onChange(of: session.showsBookmarks) { _, showsBookmarks in
            if isActive, !showsBookmarks { activateBrowser() }
        }
        .onChange(of: session.page.isLoading) { _, loading in
            guard isActive, loading,
                  focusedAddress == session.id || tabFocus.view?.window.map(tabFocus.contains) == true else { return }
            activateBrowser()
        }
        .onChange(of: store.sessions.map(\.id)) { previous, current in
            let id = store.selectedSessionID
            guard isActive, !previous.contains(id), current.contains(id),
                  store.selectedSession.address.isEmpty else { return }
            DispatchQueue.main.async {
                guard isActive, store.selectedSessionID == id,
                      store.selectedSession.address.isEmpty else { return }
                focusedAddress = id
            }
        }
        .onChange(of: isActive) { _, active in
            if active { activateBrowser() }
        }
    }

    private func activateBrowser() {
        tabFocus.activate()
        guard !store.selectedSession.showsBookmarks else { return }
        focusedAddress = nil
        webFocusRequest = UUID()
    }
}

private struct RetainedBrowserSessions: NSViewRepresentable {
    let sessions: [BrowserSession]
    let selection: BrowserSession.ID
    let webFocusRequest: UUID
    @Binding var bookmarkFocusRequest: BrowserSession.ID?
    let focusAddress: () -> Void
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { BrowserContainerView() }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let ids = Set(sessions.map(\.id))
        for id in Array(coordinator.pages.keys) where !ids.contains(id) {
            guard let page = coordinator.pages.removeValue(forKey: id) else { continue }
            resignFocus(in: page)
            page.removeFromSuperview()
        }
        for session in sessions {
            let sessionView = BrowserSessionView(
                session: session,
                focusRequested: Binding(
                    get: { bookmarkFocusRequest == session.id },
                    set: { if !$0, bookmarkFocusRequest == session.id { bookmarkFocusRequest = nil } }
                ),
                focusAddress: focusAddress
            ).environment(\.self, environment)
            if coordinator.pages[session.id] == nil, session.id == selection {
                let page = NSHostingView(rootView: AnyView(sessionView))
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
            page.rootView = AnyView(sessionView)
        }
        assert(Set(coordinator.pages.keys).isSubset(of: ids))
        assert(coordinator.pages.values.filter { !$0.isHidden }.count == 1)
        if coordinator.webFocusRequest != webFocusRequest {
            coordinator.webFocusRequest = webFocusRequest
            if let page = coordinator.pages[selection],
               sessions.contains(where: { $0.id == selection && !$0.showsBookmarks }) {
                DispatchQueue.main.async { [weak container, weak page] in
                    guard coordinator.webFocusRequest == webFocusRequest,
                          let container, let page, !page.isHiddenOrHasHiddenAncestor else { return }
                    container.layoutSubtreeIfNeeded()
                    (container as? BrowserContainerView)?.focusWebContent(in: page)
                }
            }
        }
    }

    private func resignFocus(in page: NSView) {
        if let responder = page.window?.firstResponder as? NSView,
           responder.isDescendant(of: page) {
            page.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator {
        var pages: [BrowserSession.ID: NSHostingView<AnyView>] = [:]
        var webFocusRequest: UUID?
    }
}

final class BrowserContainerView: NSView {
    @discardableResult
    func focusWebContent(in view: NSView) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, !view.isHiddenOrHasHiddenAncestor,
              view.isDescendant(of: self), let window else { return false }
        if let webView = view as? WKWebView {
            if let responder = window.firstResponder as? NSView,
               responder.isDescendant(of: webView) { return true }
            return window.makeFirstResponder(webView)
        }
        return view.subviews.contains { focusWebContent(in: $0) }
    }

    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            var view = window?.firstResponder as? NSView
            while let current = view, current !== self {
                if current is WKWebView, current.isDescendant(of: self),
                   !current.isHiddenOrHasHiddenAncestor {
                    // WebKit has already received this key; stop its unhandled fallback from beeping.
                    return
                }
                view = current.superview
            }
        }
        super.keyDown(with: event)
    }
}

private struct BrowserSessionView: View {
    let session: BrowserSession
    @Binding var focusRequested: Bool
    let focusAddress: () -> Void
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData
    @FocusState private var focusedBookmark: Bookmark.ID?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if session.showsBookmarks {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            Grid(horizontalSpacing: 24, verticalSpacing: 24) {
                                ForEach(bookmarkRows.indices, id: \.self) { row in
                                    GridRow {
                                        ForEach(bookmarkRows[row]) { bookmark in
                                            BookmarkButton(
                                                bookmark: bookmark, focus: $focusedBookmark,
                                                move: { moveBookmark($0, to: bookmark.id) },
                                                moveFocus: { moveFocus(from: bookmark.id, backwards: $0) }
                                            ) {
                                                focusedBookmark = nil
                                                session.address = bookmark.url.absoluteString
                                                session.loadAddress()
                                            }
                                            .id(bookmark.id)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                        }
                        .onChange(of: focusedBookmark) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            } else {
                WebView(session.page)
                    .webViewElementFullscreenBehavior(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: session.page.url) { _, url in
            if let url {
                session.address = url.absoluteString
            }
        }
        .onChange(of: focusRequested, initial: true) { _, requested in
            guard requested else { return }
            focusRequested = false
            if session.showsBookmarks, let first = bookmarks.first {
                focusedBookmark = first.id
            } else {
                focusAddress()
            }
        }
        .alert("Unable to Save Bookmark Order", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
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

    private func moveBookmark(_ id: Bookmark.ID, to target: Bookmark.ID) -> Bool {
        do {
            var ordered = try BookmarkStorage.decode(bookmarkData)
            guard id != target,
                  let source = ordered.firstIndex(where: { $0.id == id }),
                  let destination = ordered.firstIndex(where: { $0.id == target }) else { return false }
            let bookmark = ordered.remove(at: source)
            ordered.insert(bookmark, at: destination)
            for index in ordered.indices { ordered[index].sortOrder = index }
            bookmarkData = try BookmarkStorage.encode(ordered)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func moveFocus(from id: Bookmark.ID, backwards: Bool) {
        let ordered = bookmarks
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let next = index + (backwards ? -1 : 1)
        if ordered.indices.contains(next) {
            focusedBookmark = ordered[next].id
        } else {
            focusedBookmark = nil
            focusAddress()
        }
    }
}

private struct BookmarkButton: View {
    let bookmark: Bookmark
    let focus: FocusState<Bookmark.ID?>.Binding
    let move: (Bookmark.ID) -> Bool
    let moveFocus: (Bool) -> Void
    let action: () -> Void
    @State private var icon: Image?
    @State private var isDropTarget = false

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
        .focusable()
        .focused(focus, equals: bookmark.id)
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            action()
            return .handled
        }
        .onKeyPress(.tab, phases: .down) { press in
            guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
            moveFocus(press.modifiers.contains(.shift))
            return .handled
        }
        .draggable(bookmark.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard items.count == 1, let item = items.first, let id = UUID(uuidString: item) else { return false }
            return move(id)
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(-6)
                    .allowsHitTesting(false)
            }
        }
        .task(id: bookmark.url) {
            icon = nil
            guard let metadata = try? await LinkMetadata(fetching: bookmark.url, timeout: .seconds(30))
            else { return }
            icon = try? await metadata.media(.icon, as: Image.self)
        }
    }
}
