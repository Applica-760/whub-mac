import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct FileExplorerView: View {
    let onFileSelect: () -> Void
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var fileViewerStore: FileViewerStore
    @StateObject private var store = FileExplorerStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Project or Worktree", selection: $store.selectedRootURL) {
                    if store.availableURLs(projects: projects).isEmpty {
                        Text("---").tag(URL?.none)
                    }
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(URL(fileURLWithPath: project.path)))
                    }
                    ForEach(store.worktreeURLs, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                // Reserve the trigger position; expanded actions overlay the explorer.
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider()
                .padding(.horizontal)

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            } else {
                if let gitErrorMessage = store.gitErrorMessage {
                    Text(gitErrorMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                if let watchError = store.watchError {
                    Text(watchError)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                if let directoryErrorMessage = store.directoryErrorMessage {
                    Text(directoryErrorMessage)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                FileTreeView(
                    store: store,
                    basePath: store.basePath(projects: projects),
                    gitChanges: fileViewerStore.gitChanges,
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
        .overlay(alignment: .topTrailing) {
            GeometryReader { geometry in
                ExplorerActionsView(
                    availableWidth: min(280, max(36, geometry.size.width - 32)),
                    canRefresh: store.selectedRootURL != nil
                ) {
                    fileViewerStore.refresh()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
            }
        }
        .focusedSceneValue(
            \.projectNavigation,
            ProjectNavigation(urls: store.availableURLs(projects: projects), selection: $store.selectedRootURL)
        )
        .onAppear {
            store.validateSelection(projects: projects)
            store.startWatching(viewerStore: fileViewerStore)
        }
        .onDisappear {
            store.stopWatching()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onChange(of: store.availableURLs(projects: projects)) { _, _ in
            store.validateSelection(projects: projects)
        }
        .task(id: WorktreeLoadID(
            projectPaths: projects.compactMap { $0.host is LocalHost ? $0.path : nil },
            refreshID: fileViewerStore.refreshID
        )) {
            store.loadWorktrees(projects: projects)
        }
        .task(id: ExplorerLoadID(
            rootURL: store.selectedRootURL,
            refreshID: fileViewerStore.refreshID
        )) {
            await store.load(projects: projects, context: context, viewerStore: fileViewerStore)
        }
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
