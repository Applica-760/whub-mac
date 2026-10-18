import Foundation

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var sortOrder: Int
}

enum BookmarkStorageError: LocalizedError {
    case duplicateURL

    var errorDescription: String? { "This URL is already bookmarked." }
}

enum BookmarkStorage {
    static let key = "browser.bookmarks"
    static let initialData = Data("[]".utf8)

    static func decode(_ data: Data) throws -> [Bookmark] {
        struct StoredBookmark: Decodable {
            let id: UUID
            let title: String
            let url: URL
            let sortOrder: Int?
        }

        return try JSONDecoder().decode([StoredBookmark].self, from: data)
            .enumerated()
            .map { index, stored in
                Bookmark(id: stored.id, title: stored.title, url: stored.url,
                         sortOrder: stored.sortOrder ?? index)
            }
            .enumerated()
            .sorted {
                if $0.element.sortOrder == $1.element.sortOrder { return $0.offset < $1.offset }
                return $0.element.sortOrder < $1.element.sortOrder
            }
            .map(\.element)
    }

    static func encode(_ bookmarks: [Bookmark]) throws -> Data {
        try JSONEncoder().encode(bookmarks)
    }

    static func save(_ bookmark: Bookmark, in data: Data) throws -> Data {
        var bookmarks = try decode(data)
        guard !bookmarks.contains(where: { $0.id != bookmark.id && $0.url == bookmark.url }) else {
            throw BookmarkStorageError.duplicateURL
        }
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
        } else {
            bookmarks.append(bookmark)
        }
        return try encode(bookmarks)
    }

    static func remove(_ id: Bookmark.ID, from data: Data) throws -> Data {
        var bookmarks = try decode(data)
        bookmarks.removeAll { $0.id == id }
        return try encode(bookmarks)
    }
}
