import Combine
import Foundation
import Observation
import WebKit

@Observable
final class BrowserSession: Identifiable {
    let id = UUID()
    let page = WebPage()
    var address = ""
    var showsBookmarks = true

    var title: String {
        page.title.isEmpty ? page.url?.host ?? "New Tab" : page.title
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

    init() {
        let session = BrowserSession()
        sessions = [session]
        selectedSessionID = session.id
    }

    var selectedSession: BrowserSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = BrowserSession()
        sessions.append(session)
        selectedSessionID = session.id
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
              url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }
}
