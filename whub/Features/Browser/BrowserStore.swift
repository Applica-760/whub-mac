import Combine
import Foundation
import WebKit

final class BrowserStore: ObservableObject {
    let page = WebPage()
    @Published var address = ""

    var browserURL: URL? {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let url = URL(string: value.contains("://") ? value : "https://\(value)")
        guard let url,
              url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }

    func loadAddress() {
        guard let url = browserURL else { return }
        address = url.absoluteString
        page.load(url)
    }
}
