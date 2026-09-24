import SwiftUI

struct BookmarkSettingsView: View {
    @AppStorage(BookmarkStorage.key) private var bookmarkData = BookmarkStorage.initialData
    @State private var selection: Bookmark.ID?
    @State private var editing: BookmarkRow?
    @State private var editingColumn: Column?
    @FocusState private var focusedCell: Cell?
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in cell(row, column: .name) }
                TableColumn("URL") { row in cell(row, column: .url) }
            }
            .onChange(of: focusedCell) { previous, current in
                if let previous, previous.id != current?.id, editing?.id == previous.id {
                    save()
                }
            }

            HStack {
                ControlGroup {
                    Button("Add Bookmark", systemImage: "plus") {
                        startEdit(BookmarkRow(), column: .name)
                    }
                        .disabled(editing?.isNew == true)
                    Button("Remove Bookmark", systemImage: "minus") {
                        if editing?.isNew == true && selection == editing?.id {
                            cancel()
                        } else {
                            showsDeleteConfirmation = true
                        }
                    }
                    .disabled(selection == nil)
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
        }
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

    @ViewBuilder
    private func cell(_ row: BookmarkRow, column: Column) -> some View {
        let target = Cell(id: row.id, column: column)
        if editing?.id == row.id && (editing?.isNew == true || editingColumn == column) {
            TextField(column == .name ? "Name" : "URL", text: text(column))
                .textFieldStyle(.plain)
                .focused($focusedCell, equals: target)
                .onSubmit {
                    focusedCell = editing?.isNew == true && column == .name
                        ? Cell(id: row.id, column: .url) : nil
                }
                .onExitCommand { cancel() }
        } else {
            Text(column == .name ? row.title : row.address)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startEdit(row, column: column) }
        }
    }

    private var bookmarks: [Bookmark] {
        (try? BookmarkStorage.decode(bookmarkData)) ?? []
    }

    private var rows: [BookmarkRow] {
        var result: [BookmarkRow] = []
        for bookmark in bookmarks { result.append(BookmarkRow(bookmark)) }
        if let editing, editing.isNew { result.append(editing) }
        return result
    }

    private var selectedBookmark: Bookmark? {
        bookmarks.first { $0.id == selection }
    }

    private func text(_ column: Column) -> Binding<String> {
        Binding(
            get: { column == .name ? editing?.title ?? "" : editing?.address ?? "" },
            set: {
                if column == .name { editing?.title = $0 }
                else { editing?.address = $0 }
            }
        )
    }

    private func startEdit(_ row: BookmarkRow, column: Column) {
        guard save() else { return }
        editing = row
        editingColumn = column
        if row.isNew { selection = row.id }
        focusedCell = Cell(id: row.id, column: column)
    }

    @discardableResult
    private func save() -> Bool {
        guard let editing else { return true }
        let title = editing.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Enter a name."
            return false
        }
        guard let url = BrowserStore.url(from: editing.address) else {
            errorMessage = "Enter a valid HTTP or HTTPS URL."
            return false
        }
        do {
            let bookmark = Bookmark(id: editing.id, title: title, url: url)
            bookmarkData = try BookmarkStorage.save(bookmark, in: bookmarkData)
            self.editing = nil
            editingColumn = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func cancel() {
        if editing?.isNew == true { selection = nil }
        editing = nil
        editingColumn = nil
        focusedCell = nil
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

private struct BookmarkRow: Identifiable {
    let id: Bookmark.ID
    var title: String
    var address: String
    let isNew: Bool

    init(_ bookmark: Bookmark) {
        id = bookmark.id
        title = bookmark.title
        address = bookmark.url.absoluteString
        isNew = false
    }

    init() {
        id = UUID()
        title = ""
        address = ""
        isNew = true
    }
}

private enum Column: Hashable {
    case name, url
}

private struct Cell: Hashable {
    let id: Bookmark.ID
    let column: Column
}
