import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: (URL) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @State private var selectedProjectID: PersistentIdentifier?
    @State private var rootURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Project", selection: $selectedProjectID) {
                if projects.isEmpty {
                    Text("---").tag(PersistentIdentifier?.none)
                } else {
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.persistentModelID))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else {
                FileOutlineView(rootURL: rootURL, onFileSelect: onFileSelect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedProjectID = projects.first?.persistentModelID
        }
        .onChange(of: projects.map(\.persistentModelID)) { _, ids in
            if !ids.contains(where: { $0 == selectedProjectID }) {
                selectedProjectID = ids.first
            }
        }
        .task(id: selectedProjectID) {
            rootURL = nil
            errorMessage = nil
            guard let project = selectedProject else { return }
            guard project.host is LocalHost else {
                errorMessage = "Remote project files are not available yet."
                return
            }
            do {
                let path = try await ProjectStore(context: context).resolvePath(for: project)
                guard !Task.isCancelled else { return }
                rootURL = URL(fileURLWithPath: path)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private var selectedProject: Project? {
        projects.first { $0.persistentModelID == selectedProjectID }
    }
}
