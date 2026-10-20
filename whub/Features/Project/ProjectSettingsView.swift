import SwiftData
import SwiftUI
import WhubCore

struct ProjectSettingsView: View {
    @Query(sort: \Project.name) private var projects: [Project]
    @Query(sort: \WhubCore.Host.name) private var hosts: [WhubCore.Host]
    @Environment(\.modelContext) private var context
    @State private var selection: String?
    @State private var showsDeleteConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        EditableTable(
            rows: projects.map { ProjectRow($0) },
            columns: [
                .init(id: "isVisibleInExplorer", title: "", value: { _ in "" }, content: { row in
                    AnyView(
                        Toggle("Show in Explorer", isOn: row.isVisibleInExplorer)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    )
                }, minWidth: 24, idealWidth: 24, maxWidth: 24),
                .init(id: "name", title: "Name", value: { $0.name }, text: \.name),
                .init(id: "gitURL", title: "Git URL", value: { $0.gitURL }, text: \.gitURL,
                      minWidth: 160, idealWidth: 320, maxWidth: 500),
                .init(id: "host", title: "Host", value: { _ in "" }, content: { row in
                    AnyView(
                        Picker("Host", selection: row.hostID) {
                            ForEach(hosts) { host in
                                Text(host.name).tag(host.persistentModelID)
                            }
                        }
                        .labelsHidden()
                    )
                }),
            ],
            selection: $selection,
            addTitle: "Add Project",
            removeTitle: "Remove Project",
            errorTitle: "Unable to Save Project",
            canAdd: !hosts.isEmpty,
            onAdd: { hosts.first.map { ProjectRow(host: $0) } },
            onSave: save,
            onRemove: { showsDeleteConfirmation = true }
        )
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

    private var selectedProject: Project? {
        projects.first { String(describing: $0.persistentModelID) == selection }
    }

    private func save(_ row: ProjectRow) throws -> String {
        guard let host = hosts.first(where: { $0.persistentModelID == row.hostID }) else {
            throw ProjectSettingsError.hostRequired
        }
        let gitURL = row.gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = ProjectStore(context: context)
        if let project = row.project {
            try store.edit(project, name: row.name, gitURL: gitURL.isEmpty ? nil : gitURL, host: host,
                           isVisibleInExplorer: row.isVisibleInExplorer)
            return row.id
        }
        let project = try store.add(name: row.name, gitURL: gitURL.isEmpty ? nil : gitURL, host: host,
                                    isVisibleInExplorer: row.isVisibleInExplorer)
        return String(describing: project.persistentModelID)
    }

    private func delete() {
        guard let project = selectedProject else { return }
        do {
            try ProjectStore(context: context).delete(project)
            selection = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum ProjectSettingsError: LocalizedError {
    case hostRequired

    var errorDescription: String? { "Select a host." }
}

private struct ProjectRow: Identifiable {
    let id: String
    let project: Project?
    var name: String
    var gitURL: String
    var hostID: PersistentIdentifier
    var isVisibleInExplorer = true

    init(_ project: Project) {
        id = String(describing: project.persistentModelID)
        self.project = project
        name = project.name
        gitURL = project.gitURL ?? ""
        hostID = project.host.persistentModelID
        isVisibleInExplorer = project.isVisibleInExplorer
    }

    init(host: WhubCore.Host) {
        id = UUID().uuidString
        project = nil
        name = ""
        gitURL = ""
        hostID = host.persistentModelID
    }
}
