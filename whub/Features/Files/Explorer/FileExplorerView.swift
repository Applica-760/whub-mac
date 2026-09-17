import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: (URL) -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var selectedProject: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Project", selection: $selectedProject) {
                if projects.isEmpty {
                    Text("---").tag(nil as String?)
                } else {
                    ForEach(projects, id: \.name) { project in
                        Text(project.name).tag(Optional(project.name))
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.horizontal)

            FileOutlineView(rootURL: rootURL, onFileSelect: onFileSelect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedProject = projects.first?.name
        }
        .onChange(of: projects.map(\.name)) { _, names in
            if !names.contains(selectedProject ?? "") {
                selectedProject = names.first
            }
        }
    }

    private var rootURL: URL? {
        guard
            let selectedProject,
            let project = projects.first(where: { $0.name == selectedProject }),
            let resource = project.resource as? LocalResource
        else {
            return nil
        }
        return URL(fileURLWithPath: resource.localPath)
    }
}

#Preview {
    FileExplorerView { _ in }
}
