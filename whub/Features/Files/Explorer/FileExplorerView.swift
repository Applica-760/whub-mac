import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: () -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var fileViewerStore: FileViewerStore
    @State private var selectedRootURL: URL?
    @State private var worktreeURLs: [URL] = []
    @State private var rootURL: URL?
    @State private var errorMessage: String?
    @State private var gitErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Project or Worktree", selection: $selectedRootURL) {
                    if availableURLs.isEmpty {
                        Text("---").tag(URL?.none)
                    }
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(URL(fileURLWithPath: project.path)))
                    }
                    ForEach(worktreeURLs, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button {
                    fileViewerStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh files and Git status")
                .disabled(selectedRootURL == nil)
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
                    gitChanges: fileViewerStore.gitChanges,
                    refreshID: fileViewerStore.refreshID,
                    onFilePreview: { fileURL in
                        fileViewerStore.preview(fileURL)
                        onFileSelect()
                    },
                    onFileOpen: { fileURL in
                        fileViewerStore.open(fileURL)
                        onFileSelect()
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            selectedRootURL = availableURLs.first
        }
        .onChange(of: availableURLs) { _, urls in
            if !urls.contains(where: { $0 == selectedRootURL }) {
                selectedRootURL = urls.first
            }
        }
        .task(id: WorktreeLoadID(
            projectPaths: projects.compactMap { $0.host is LocalHost ? $0.path : nil },
            refreshID: fileViewerStore.refreshID
        )) {
            loadWorktrees()
        }
        .task(id: ExplorerLoadID(
            rootURL: selectedRootURL,
            refreshID: fileViewerStore.refreshID
        )) {
            rootURL = nil
            fileViewerStore.gitChanges = [:]
            errorMessage = nil
            gitErrorMessage = nil
            guard let selectedRootURL else { return }
            do {
                let path: String
                if let project = projects.first(where: { $0.path == selectedRootURL.path }) {
                    guard project.host is LocalHost else {
                        errorMessage = "Remote project files are not available yet."
                        return
                    }
                    path = try await ProjectStore(context: context).resolvePath(for: project)
                } else {
                    path = selectedRootURL.path
                }
                guard !Task.isCancelled else { return }
                let url = URL(fileURLWithPath: path)
                rootURL = url
                do {
                    let changes = try await Git.changes(at: url)
                    guard !Task.isCancelled else { return }
                    fileViewerStore.gitChanges = changes
                } catch GitError.notRepository {
                    guard !Task.isCancelled else { return }
                    fileViewerStore.gitChanges = [:]
                } catch {
                    guard !Task.isCancelled else { return }
                    fileViewerStore.gitChanges = [:]
                    gitErrorMessage = error.localizedDescription
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private var availableURLs: [URL] {
        projects.map { URL(fileURLWithPath: $0.path) } + worktreeURLs
    }

    private func loadWorktrees() {
        let localProjects = projects.filter { $0.host is LocalHost }
        worktreeURLs = Set(localProjects.map { $0.host.worktreesPath }).flatMap { path in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return urls.filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
                return localProjects.contains { project in
                    let prefix = project.name + "-"
                    guard url.lastPathComponent.hasPrefix(prefix),
                          let number = Int(url.lastPathComponent.dropFirst(prefix.count)),
                          number > 0 else { return false }
                    return url.path == project.worktreePath(issueNumber: number)
                }
            }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

}

private struct ExplorerLoadID: Equatable {
    let rootURL: URL?
    let refreshID: Int
}

private struct WorktreeLoadID: Equatable {
    let projectPaths: [String]
    let refreshID: Int
}
