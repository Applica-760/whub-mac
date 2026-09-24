import SwiftUI

struct BookmarkSettingsView: View {
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData
    @State private var selection: Bookmark.ID?
    @State private var editingID: Bookmark.ID?
    @State private var title = ""
    @State private var address = ""
    @State private var showsEditor = false
    @State private var showsDeleteConfirmation = false
    @State private var showsError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 8) {
            Table(bookmarks, selection: $selection) {
                TableColumn("Name", value: \.title)
                TableColumn("URL") { bookmark in
                    Text(bookmark.url.absoluteString)
                }
            }
            .onTapGesture(count: 2, perform: edit)

            HStack {
                ControlGroup {
                    Button("Add Bookmark", systemImage: "plus", action: add)
                    Button("Remove Bookmark", systemImage: "minus") {
                        showsDeleteConfirmation = true
                    }
                    .disabled(selectedBookmark == nil)
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
        }
        .sheet(isPresented: $showsEditor) {
            VStack(spacing: 24) {
                Form {
                    TextField("Name", text: $title)
                    TextField("URL", text: $address)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showsEditor = false }
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .padding(24)
            .frame(width: 480)
        }
        .alert("Delete Bookmark?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Delete \(selectedBookmark?.title ?? "this bookmark")?")
        }
        .alert("Unable to Save Bookmarks", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var bookmarks: [Bookmark] {
        (try? BookmarkStorage.decode(bookmarkData)) ?? []
    }

    private var selectedBookmark: Bookmark? {
        bookmarks.first { $0.id == selection }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = BookmarkStorage.url(from: address)
        else { return false }
        return !bookmarks.contains { $0.id != editingID && $0.url == url }
    }

    private func add() {
        editingID = nil
        title = ""
        address = ""
        showsEditor = true
    }

    private func edit() {
        guard let bookmark = selectedBookmark else { return }
        editingID = bookmark.id
        title = bookmark.title
        address = bookmark.url.absoluteString
        showsEditor = true
    }

    private func save() {
        guard canSave, let url = BookmarkStorage.url(from: address) else { return }
        do {
            var items = try BookmarkStorage.decode(bookmarkData)
            if let editingID, let index = items.firstIndex(where: { $0.id == editingID }) {
                items[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                items[index].url = url
            } else {
                items.append(Bookmark(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url))
            }
            bookmarkData = try BookmarkStorage.encode(items)
            showsEditor = false
        } catch {
            show(error)
        }
    }

    private func delete() {
        guard let selection else { return }
        do {
            var items = try BookmarkStorage.decode(bookmarkData)
            items.removeAll { $0.id == selection }
            bookmarkData = try BookmarkStorage.encode(items)
            self.selection = nil
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showsError = true
    }
}
