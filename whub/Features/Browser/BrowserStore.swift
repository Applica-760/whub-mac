import Combine
import Foundation
import Observation
import WebKit

@Observable
final class BrowserSession: Identifiable {
    let id = UUID()
    let page: WebPage
    var address = ""
    var showsBookmarks = true

    init(navigationDecider: some WebPage.NavigationDeciding) {
        page = WebPage(navigationDecider: navigationDecider)
    }

    var title: String {
        page.title.isEmpty ? page.url.map { $0.isFileURL ? $0.lastPathComponent : $0.host ?? "New" } ?? "New" : page.title
    }

    func loadAddress() {
        guard let url = BrowserStore.url(from: address) else { return }
        address = url.absoluteString
        page.load(url)
        showsBookmarks = false
    }
}

final class BrowserStore: ObservableObject {
    @Published private(set) var sessions: [BrowserSession]
    @Published private(set) var selectedSessionID: BrowserSession.ID
    private let navigationDecider: BrowserNavigationDecider

    init() {
        let navigationDecider = BrowserNavigationDecider()
        self.navigationDecider = navigationDecider
        let session = BrowserSession(navigationDecider: navigationDecider)
        sessions = [session]
        selectedSessionID = session.id
        navigationDecider.open = { [weak self] request in self?.open(request) }
    }

    var selectedSession: BrowserSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = BrowserSession(navigationDecider: navigationDecider)
        sessions.append(session)
        selectedSessionID = session.id
    }

    func open(_ url: URL) {
        open(URLRequest(url: url))
    }

    private func open(_ request: URLRequest) {
        guard let url = request.url, Self.url(from: url.absoluteString) != nil else { return }
        let previousSession = selectedSession
        add()
        selectedSession.address = url.absoluteString
        selectedSession.page.load(request)
        selectedSession.showsBookmarks = false
        assert(selectedSessionID != previousSession.id && sessions.contains { $0 === previousSession })
    }

    func remove(_ id: BrowserSession.ID) {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }

        sessions.remove(at: index)
        guard selectedSessionID == id else { return }
        selectedSessionID = sessions[min(index, sessions.endIndex - 1)].id
    }

    func move(_ id: BrowserSession.ID, before target: BrowserSession.ID?) {
        guard let reordered = reorderedTabs(sessions, moving: id, before: target, identifiedBy: \.id)
        else { return }
        sessions = reordered
    }

    func select(_ id: BrowserSession.ID) {
        selectedSessionID = id
    }

    static func url(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value.contains("://") ? value : "https://\(value)"),
              url.isFileURL || (url.host != nil && ["http", "https"].contains(url.scheme?.lowercased()))
        else { return nil }
        return url
    }
}

private final class BrowserNavigationDecider: WebPage.NavigationDeciding {
    var open: ((URLRequest) -> Void)?

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard action.target == nil else { return .allow }
        guard let url = action.request.url,
              ["http", "https"].contains(url.scheme?.lowercased()) else { return .cancel }
        // shortcut: URL navigation only; use native popup creation if window.opener support is needed.
        open?(action.request)
        return .cancel
    }
}
