import Foundation

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
}

enum BookmarkStorage {
    static let key = "browser.bookmarks"
    static let initialData = Data("[]".utf8)

    static func decode(_ data: Data) throws -> [Bookmark] {
        try JSONDecoder().decode([Bookmark].self, from: data)
    }

    static func encode(_ bookmarks: [Bookmark]) throws -> Data {
        try JSONEncoder().encode(bookmarks)
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
