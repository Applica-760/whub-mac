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
        let configuration = WebPage.Configuration()
        BrowserKeyboardNavigation.install(in: configuration.userContentController)
        page = WebPage(configuration: configuration, navigationDecider: navigationDecider)
        // shortcut: fixed Safari version for site compatibility; update when supported WebKit versions change.
        page.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Safari/605.1.15"
    }

    var title: String {
        page.title.isEmpty ? page.url.map { $0.isFileURL ? $0.lastPathComponent : $0.host ?? "New" } ?? "New" : page.title
    }

    func loadAddress() {
        guard let url = BrowserStore.navigationURL(from: address) else { return }
        address = url.absoluteString
        page.load(url)
        showsBookmarks = false
    }
}

final class BrowserStore: ObservableObject {
    static func githubIssuesURL(_ gitURL: String) -> URL? {
        let value = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.hasPrefix("git@github.com:")
            ? "https://github.com/" + value.dropFirst("git@github.com:".count) : value
        guard let components = URLComponents(string: normalized),
              ["https", "http", "ssh"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.lowercased() == "github.com", components.query == nil, components.fragment == nil else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/issues")
    }

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

    func openIssues(_ url: URL) {
        if let existing = sessions.first(where: { session in
            guard !session.showsBookmarks,
                  let current = session.page.url ?? URL(string: session.address) else { return false }
            return Self.isIssuesURL(current, under: url)
        }) {
            select(existing.id)
            return
        }

        if let empty = sessions.first(where: { $0.page.url == nil && $0.address.isEmpty && $0.showsBookmarks }) {
            select(empty.id)
        } else {
            add()
        }
        selectedSession.address = url.absoluteString
        selectedSession.page.load(URLRequest(url: url))
        selectedSession.showsBookmarks = false
    }

    static func isIssuesURL(_ current: URL, under root: URL) -> Bool {
        guard current.scheme?.lowercased() == root.scheme?.lowercased(),
              current.host?.lowercased() == root.host?.lowercased(), current.port == root.port else { return false }
        let path = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        return current.path == path || current.path.hasPrefix(path + "/")
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
        guard let index = sessions.firstIndex(where: { $0.id == id })
        else { return }

        if sessions.count == 1 {
            let replacement = BrowserSession(navigationDecider: navigationDecider)
            sessions = [replacement]
            selectedSessionID = replacement.id
            return
        }
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

    static func navigationURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.contains("://") { return url(from: value) }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let direct = url(from: value), let host = direct.host,
           host.contains(".") || host == "localhost" || host.contains(":") {
            return direct
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: value)]
        search.percentEncodedQuery = search.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return search.url
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
