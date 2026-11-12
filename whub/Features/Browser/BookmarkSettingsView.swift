import SwiftUI

struct BookmarkSettingsView: View {
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData
    @State private var selection: Bookmark.ID?
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        EditableTable(
            rows: bookmarks.map { BookmarkRow($0) },
            columns: [
                .init(id: "name", title: "Name", value: { $0.title }, text: \.title),
                .init(id: "url", title: "URL", value: { $0.address }, text: \.address,
                      minWidth: 180, idealWidth: 400, maxWidth: 600),
            ],
            selection: $selection,
            addTitle: "Add Bookmark",
            removeTitle: "Remove Bookmark",
            errorTitle: "Unable to Save Bookmark",
            onAdd: { BookmarkRow() },
            onSave: save,
            onRemove: { showsDeleteConfirmation = true }
        )
        .alert("Delete Bookmark?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Delete \(selectedBookmark?.title ?? "this bookmark")?")
        }
        .alert("Unable to Save Bookmark", isPresented: Binding(
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

    private var selectedBookmark: Bookmark? {
        bookmarks.first { $0.id == selection }
    }

    private func save(_ row: BookmarkRow) throws -> Bookmark.ID {
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw BookmarkSettingsError.nameRequired }
        guard let url = BrowserStore.url(from: row.address) else {
            throw BookmarkSettingsError.invalidURL
        }
        let current = try BookmarkStorage.decode(bookmarkData)
        let sortOrder = current.first { $0.id == row.id }?.sortOrder
            ?? ((current.last?.sortOrder ?? -1) + 1)
        let bookmark = Bookmark(id: row.id, title: title, url: url, sortOrder: sortOrder)
        bookmarkData = try BookmarkStorage.save(bookmark, in: bookmarkData)
        return bookmark.id
    }

    private func delete() {
        guard let selection else { return }
        do {
            bookmarkData = try BookmarkStorage.remove(selection, from: bookmarkData)
            self.selection = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum BookmarkSettingsError: LocalizedError {
    case nameRequired
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .nameRequired: "Enter a name."
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        }
    }
}

private struct BookmarkRow: Identifiable {
    let id: Bookmark.ID
    var title: String
    var address: String

    init(_ bookmark: Bookmark) {
        id = bookmark.id
        title = bookmark.title
        address = bookmark.url.absoluteString
    }

    init() {
        id = UUID()
        title = ""
        address = ""
    }
}
