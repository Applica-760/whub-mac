import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: (URL) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @State private var selectedProjectID: PersistentIdentifier?
    @State private var displayedProjectID: PersistentIdentifier?
    @State private var rootURL: URL?
    @State private var gitChanges: [URL: GitChange] = [:]
    @State private var refreshID = 0
    @State private var errorMessage: String?
    @State private var gitErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
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

                Button {
                    refreshID += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh files and Git status")
                .disabled(selectedProjectID == nil)
            }
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
                if let gitErrorMessage {
                    Text(gitErrorMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                FileTreeView(
                    rootURL: rootURL,
                    gitChanges: gitChanges,
                    refreshID: refreshID,
                    onFileSelect: onFileSelect
                )
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
        .task(id: ExplorerLoadID(projectID: selectedProjectID, refreshID: refreshID)) {
            if displayedProjectID != selectedProjectID {
                displayedProjectID = selectedProjectID
                rootURL = nil
                gitChanges = [:]
            }
            errorMessage = nil
            gitErrorMessage = nil
            guard let project = selectedProject else { return }
            guard project.host is LocalHost else {
                errorMessage = "Remote project files are not available yet."
                return
            }
            do {
                let path = try await ProjectStore(context: context).resolvePath(for: project)
                guard !Task.isCancelled else { return }
                let url = URL(fileURLWithPath: path)
                rootURL = url
                do {
                    let changes = try await Git.changes(at: url)
                    guard !Task.isCancelled else { return }
                    gitChanges = changes
                } catch GitError.notRepository {
                    guard !Task.isCancelled else { return }
                    gitChanges = [:]
                } catch {
                    guard !Task.isCancelled else { return }
                    gitChanges = [:]
                    gitErrorMessage = error.localizedDescription
                }
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

private struct ExplorerLoadID: Equatable {
    let projectID: PersistentIdentifier?
    let refreshID: Int
}
