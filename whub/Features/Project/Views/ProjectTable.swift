import SwiftData
import SwiftUI
import WhubCore

struct ProjectTable: View {
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @State private var showsAddProject = false
    @State private var showsDeleteConfirmation = false
    @State private var showsDeleteError = false
    @State private var deleteErrorMessage = ""
    @State private var selection: String?
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(spacing: 8) {
            Table(of: ProjectTableRow.self, selection: $selection) {
                TableColumn("Property") { row in
                    Text(row.item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { select(row) })
                }
                TableColumn("Value") { row in
                    Text(row.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { select(row) })
                }
            } rows: {
                ForEach(rows) { project in
                    DisclosureTableRow(project, isExpanded: expansionBinding(for: project.id)) {
                        ForEach(project.children ?? []) { resource in
                            DisclosureTableRow(resource, isExpanded: expansionBinding(for: resource.id)) {
                                ForEach(resource.children ?? []) { field in
                                    TableRow(field)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                ControlGroup {
                    Button("Add Project", systemImage: "plus") {
                        showsAddProject = true
                    }
                    Button("Remove Project", systemImage: "minus") {
                        showsDeleteConfirmation = true
                    }
                    .disabled(selectedProject == nil)
                }
                .controlGroupStyle(.automatic)
                .labelStyle(.iconOnly)

                Spacer()
            }
        }
        .sheet(isPresented: $showsAddProject) {
            AddProjectForm()
        }
        .alert("Delete Project?", isPresented: $showsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteSelectedProject)
        } message: {
            Text("Delete \(selectedProject?.name ?? "this project")? This cannot be undone.")
        }
        .alert("Unable to Delete Project", isPresented: $showsDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage)
        }
    }

    private var rows: [ProjectTableRow] {
        projects.map { project in
            let id = String(describing: project.persistentModelID)
            return ProjectTableRow(
                id: id,
                item: project.name,
                value: "",
                children: [resourceRow(for: project.resource, id: "\(id).resource")]
            )
        }
    }

    private var selectedProject: Project? {
        projects.first { String(describing: $0.persistentModelID) == selection }
    }

    private func resourceRow(for resource: Resource, id: String) -> ProjectTableRow {
        var children = [
            ProjectTableRow(id: "\(id).workspacePath", item: "Workspace Path", value: resource.workspacePath),
            ProjectTableRow(id: "\(id).git", item: "Git", value: resource.gitURL ?? "None"),
            ProjectTableRow(id: "\(id).status", item: "Status", value: resource.statusEnabled ? "Enabled" : "Disabled"),
        ]

        let type: String
        switch resource {
        case let local as LocalResource:
            type = "Local"
            children.append(ProjectTableRow(id: "\(id).localPath", item: "Local Path", value: local.localPath))
        case let remote as RemoteResource:
            type = "Remote"
            let host = remote.host
            let hostValue = host.map { "\($0.name) (\($0.user)@\($0.hostname))" } ?? "Unassigned"
            children.append(ProjectTableRow(id: "\(id).host", item: "Host", value: hostValue))
            children.append(ProjectTableRow(id: "\(id).remotePath", item: "Remote Path", value: remote.remotePath))
        default:
            type = "Unknown"
        }

        return ProjectTableRow(id: id, item: "Resource", value: type, children: children)
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    self.expanded.insert(id)
                } else {
                    self.expanded.remove(id)
                }
            }
        )
    }

    private func select(_ row: ProjectTableRow) {
        selection = row.id
        guard row.children != nil else { return }
        if expanded.contains(row.id) {
            expanded.remove(row.id)
        } else {
            expanded.insert(row.id)
        }
    }

    private func deleteSelectedProject() {
        guard let project = selectedProject else { return }

        do {
            try ProjectStore(context: context).delete(project)
            selection = nil
        } catch {
            deleteErrorMessage = error.localizedDescription
            showsDeleteError = true
        }
    }
}

private struct ProjectTableRow: Identifiable {
    let id: String
    let item: String
    let value: String
    let children: [ProjectTableRow]?

    init(id: String, item: String, value: String, children: [ProjectTableRow]? = nil) {
        self.id = id
        self.item = item
        self.value = value
        self.children = children
    }
}
