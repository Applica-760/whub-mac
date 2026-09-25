import SwiftData
import SwiftUI
import WhubCore

struct ProjectTable: View {
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @State private var selection: String?
    @State private var editing: ProjectRow?
    @State private var editingColumn: Column?
    @FocusState private var focusedCell: Cell?
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { row in cell(row, column: .name) }
                TableColumn("Git URL") { row in cell(row, column: .gitURL) }
                TableColumn("Host") { row in
                    Picker("Host", selection: hostSelection(for: row)) {
                        ForEach(hosts) { host in
                            Text(host.name).tag(host.persistentModelID)
                        }
                    }
                    .labelsHidden()
                }
            }
            .onChange(of: focusedCell) { previous, current in
                if let previous, previous.id != current?.id, editing?.id == previous.id {
                    save()
                }
            }

            HStack {
                ControlGroup {
                    Button("Add Project", systemImage: "plus") {
                        guard let host = hosts.first else { return }
                        startEdit(ProjectRow(host: host), column: .name)
                    }
                    .disabled(hosts.isEmpty || editing?.isNew == true)
                    Button("Remove Project", systemImage: "minus") {
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
        .alert("Delete Project?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("Delete \(selectedProject?.name ?? "this project")?")
        }
        .alert("Unable to Save Project", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func cell(_ row: ProjectRow, column: Column) -> some View {
        let target = Cell(id: row.id, column: column)
        if editing?.id == row.id && (editing?.isNew == true || editingColumn == column) {
            TextField(column == .name ? "Name" : "Git URL", text: text(column))
                .textFieldStyle(.plain)
                .focused($focusedCell, equals: target)
                .onSubmit {
                    focusedCell = editing?.isNew == true && column == .name
                        ? Cell(id: row.id, column: .gitURL) : nil
                }
                .onExitCommand { cancel() }
        } else {
            Text(column == .name ? row.name : row.gitURL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { startEdit(row, column: column) }
        }
    }

    private var rows: [ProjectRow] {
        var result = projects.map { ProjectRow($0) }
        if let editing, editing.isNew { result.append(editing) }
        return result
    }

    private var selectedProject: Project? {
        projects.first { String(describing: $0.persistentModelID) == selection }
    }

    private func text(_ column: Column) -> Binding<String> {
        Binding(
            get: { column == .name ? editing?.name ?? "" : editing?.gitURL ?? "" },
            set: {
                if column == .name { editing?.name = $0 }
                else { editing?.gitURL = $0 }
            }
        )
    }

    private func hostSelection(for row: ProjectRow) -> Binding<PersistentIdentifier> {
        Binding(
            get: { editing?.id == row.id ? editing?.hostID ?? row.hostID : row.hostID },
            set: { hostID in
                if editing?.id == row.id {
                    editing?.hostID = hostID
                    if editing?.isNew == false { save() }
                } else if let project = row.project, let host = hosts.first(where: { $0.persistentModelID == hostID }) {
                    do {
                        try ProjectStore(context: context).edit(project, name: project.name, gitURL: project.gitURL, host: host)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        )
    }

    private func startEdit(_ row: ProjectRow, column: Column) {
        guard save() else { return }
        editing = row
        editingColumn = column
        if row.isNew { selection = row.id }
        focusedCell = Cell(id: row.id, column: column)
    }

    @discardableResult
    private func save() -> Bool {
        guard let editing else { return true }
        guard let host = hosts.first(where: { $0.persistentModelID == editing.hostID }) else {
            errorMessage = "Select a host."
            return false
        }
        let gitURL = editing.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let store = ProjectStore(context: context)
            if let project = editing.project {
                try store.edit(project, name: editing.name, gitURL: gitURL.isEmpty ? nil : gitURL, host: host)
            } else {
                let project = try store.add(name: editing.name, gitURL: gitURL.isEmpty ? nil : gitURL, host: host)
                selection = String(describing: project.persistentModelID)
            }
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
        guard let project = selectedProject else { return }
        do {
            try ProjectStore(context: context).delete(project)
            selection = nil
            if editing?.project?.persistentModelID == project.persistentModelID { cancel() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProjectRow: Identifiable {
    let id: String
    let project: Project?
    var name: String
    var gitURL: String
    var hostID: PersistentIdentifier

    var isNew: Bool { project == nil }

    init(_ project: Project) {
        id = String(describing: project.persistentModelID)
        self.project = project
        name = project.name
        gitURL = project.gitURL ?? ""
        hostID = project.host.persistentModelID
    }

    init(host: WhubCore.Host) {
        id = UUID().uuidString
        project = nil
        name = ""
        gitURL = ""
        hostID = host.persistentModelID
    }
}

private enum Column: Hashable {
    case name, gitURL
}

private struct Cell: Hashable {
    let id: String
    let column: Column
}
