import Combine
import Foundation
import WebKit

final class BrowserStore: ObservableObject {
    let page = WebPage()
    @Published var address = ""

    static func url(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value.contains("://") ? value : "https://\(value)"),
              url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        return url
    }

    @discardableResult
    func loadAddress() -> Bool {
        guard let url = Self.url(from: address) else { return false }
        address = url.absoluteString
        page.load(url)
        return true
    }
}
