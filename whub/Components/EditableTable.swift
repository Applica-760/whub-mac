import SwiftUI

struct EditableTable<Row: Identifiable>: View {
    struct Column: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let value: (Row) -> String
        var text: WritableKeyPath<Row, String>? = nil
        var content: ((Binding<Row>) -> AnyView)? = nil
        var minWidth: CGFloat? = nil
        var idealWidth: CGFloat? = nil
        var maxWidth: CGFloat? = nil
    }

    let rows: [Row]
    let columns: [Column]
    @Binding var selection: Row.ID?
    var addTitle: LocalizedStringKey = "Add"
    var removeTitle: LocalizedStringKey = "Remove"
    var errorTitle: LocalizedStringKey = "Unable to Save"
    var canAdd = true
    var canRemove = true
    let onAdd: () -> Row?
    var onSave: ((Row) throws -> Row.ID)? = nil
    var onRemove: (() -> Void)? = nil
    var onDoubleClick: ((Row, Column.ID) -> Void)? = nil

    @State private var editing: Row?
    @State private var editingColumn: Column.ID?
    @State private var isNew = false
    @State private var errorMessage: String?
    @FocusState private var focusedCell: Cell?

    private struct Cell: Hashable {
        let id: Row.ID
        let column: Column.ID
    }

    private var displayedRows: [Row] {
        var result = rows
        if isNew, let editing { result.append(editing) }
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            Table(displayedRows, selection: $selection) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.title) { row in
                        cell(row, column: column)
                    }
                    .width(min: column.minWidth, ideal: column.idealWidth, max: column.maxWidth)
                }
            }
            .onChange(of: focusedCell) { previous, current in
                if let previous, previous.id != current?.id, editing?.id == previous.id {
                    save()
                }
            }
            .onChange(of: rows.map(\.id)) { _, ids in
                if !isNew, let editing, !ids.contains(editing.id) { cancel() }
            }

            HStack {
                ControlGroup {
                    Button(addTitle, systemImage: "plus", action: add)
                        .disabled(!canAdd || isNew)
                    if onRemove != nil {
                        Button(removeTitle, systemImage: "minus", action: remove)
                            .disabled(!canRemove || selection == nil)
                    }
                }
                .labelStyle(.iconOnly)
                Spacer()
            }
        }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    if let editing, let editingColumn {
                        focusedCell = Cell(id: editing.id, column: editingColumn)
                    }
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func cell(_ row: Row, column: Column) -> some View {
        let target = Cell(id: row.id, column: column.id)
        if let content = column.content {
            content(rowBinding(for: row))
                .focused($focusedCell, equals: target)
                .onExitCommand { cancel() }
        } else if let keyPath = column.text,
                  editing?.id == row.id && (isNew || editingColumn == column.id) {
            TextField(column.title, text: text(keyPath, row: row), axis: .horizontal)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .focused($focusedCell, equals: target)
                .onSubmit { submit(row, column: column) }
                .onExitCommand { cancel() }
        } else {
            Text(column.value(currentRow(row)))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleClick(row, column: column) }
                .accessibilityAction(named: Text("Edit")) { doubleClick(row, column: column) }
        }
    }

    private func text(_ keyPath: WritableKeyPath<Row, String>, row: Row) -> Binding<String> {
        Binding(
            get: { editing?[keyPath: keyPath] ?? row[keyPath: keyPath] },
            set: { editing?[keyPath: keyPath] = $0 }
        )
    }

    private func rowBinding(for row: Row) -> Binding<Row> {
        Binding(
            get: { currentRow(row) },
            set: { value in
                guard errorMessage == nil else { return }
                if editing?.id != row.id {
                    guard save() else { return }
                }
                editing = value
                if !isNew { save() }
            }
        )
    }

    private func currentRow(_ row: Row) -> Row {
        guard let editing, editing.id == row.id else { return row }
        return editing
    }

    private func add() {
        guard save(), let row = onAdd() else { return }
        editing = row
        isNew = true
        selection = row.id
        editingColumn = columns.first(where: { $0.text != nil })?.id
        if let editingColumn {
            focusedCell = Cell(id: row.id, column: editingColumn)
        }
    }

    private func remove() {
        if isNew && selection == editing?.id {
            cancel()
        } else {
            onRemove?()
        }
    }

    private func submit(_ row: Row, column: Column) {
        if isNew,
           let index = columns.firstIndex(where: { $0.id == column.id }),
           let next = columns.dropFirst(index + 1).first(where: { $0.text != nil }) {
            editingColumn = next.id
            focusedCell = Cell(id: row.id, column: next.id)
        } else {
            focusedCell = nil
            save()
        }
    }

    private func doubleClick(_ row: Row, column: Column) {
        let row = currentRow(row)
        if let onDoubleClick {
            guard save() else { return }
            selection = row.id
            onDoubleClick(row, column.id)
        } else {
            startEdit(row, column: column)
        }
    }

    private func startEdit(_ row: Row, column: Column) {
        if isNew, editing?.id == row.id {
            guard column.text != nil else { return }
        } else {
            guard save(), column.text != nil, onSave != nil else { return }
            editing = row
        }
        editingColumn = column.id
        focusedCell = Cell(id: row.id, column: column.id)
    }

    @discardableResult
    private func save() -> Bool {
        guard errorMessage == nil else { return false }
        guard let editing else { return true }
        guard let onSave else { return false }
        do {
            let id = try onSave(editing)
            if isNew { selection = id }
            self.editing = nil
            editingColumn = nil
            isNew = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func cancel() {
        if isNew { selection = nil }
        editing = nil
        editingColumn = nil
        isNew = false
        focusedCell = nil
    }
}
