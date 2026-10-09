import Combine
import Foundation
import WhubCore

@MainActor
final class LocalDiffStore: ObservableObject {
    let fileURL: URL
    @Published private(set) var diff: FileDiff?
    @Published private(set) var errorMessage: String?
    @Published private(set) var watchError: String?
    @Published private(set) var isLoading = false
    private var directory: URL
    private var managementDirectories: Set<URL> = []
    private var revision = 0
    private var task: Task<Void, Never>?
    private var stopped = false
    private lazy var watcher = LocalFileWatcher { [weak self] event in
        guard let self else { return }
        if case let .changed(paths) = event {
            let targets = [fileURL.standardizedFileURL.path, fileURL.resolvingSymlinksInPath().path]
            let roots = [directory.path, directory.resolvingSymlinksInPath().path]
            guard paths.contains(where: { path in targets.contains { $0 == path || $0.hasPrefix(path + "/") } })
                || Git.needsStatusRefresh(changedPaths: paths, worktreeRoots: roots,
                                          managementDirectories: managementDirectories) else { return }
        }
        refresh()
    }

    init(fileURL: URL, directory: URL) {
        self.fileURL = fileURL
        self.directory = directory
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        revision += 1
        isLoading = true
        guard task == nil else { return }
        task = Task { [weak self] in await self?.load() }
    }

    func stop() {
        stopped = true
        revision += 1
        task?.cancel()
        watcher.stop()
        isLoading = false
    }

    private func load() async {
        defer { task = nil }
        while !stopped {
            let revision = revision
            do {
                let directories = try await Git.managementDirectories(at: directory)
                guard !stopped, self.revision == revision else { continue }
                managementDirectories = directories
                updateWatching()
                let loaded = try await Git.fileDiff(at: fileURL, in: directory)
                guard !stopped, self.revision == revision else { continue }
                // Keep a repository root that survives removal of the selected file's parent.
                directory = loaded.fileURL
                for _ in loaded.relativePath.split(separator: "/") { directory.deleteLastPathComponent() }
                updateWatching()
                diff = loaded
                errorMessage = nil
            } catch {
                guard !stopped, self.revision == revision else { continue }
                diff = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
            break
        }
    }

    private func updateWatching() {
        do {
            try watcher.start(paths: Set(managementDirectories.map(\.path)).union([directory.path]))
            watchError = nil
        } catch { watchError = error.localizedDescription }
    }
}
