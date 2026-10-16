import Foundation
import SwiftData
import WhubCore

@MainActor
final class LocalWorkspaceStore {
    private(set) var projects: [Project] = []
    private(set) var basePath: String?
    private(set) var worktreeURLs: [URL] = []
    private var loadID: LoadID?
    private var generation = UUID()

    struct LoadID: Equatable {
        let projectPaths: [String]
        let worktreePaths: [String]
        let refreshID: Int
    }

    private(set) var errorMessage: String?

    func update(host: LocalHost?, basePath: String?, id: LoadID, context: ModelContext) async {
        self.basePath = basePath
        guard loadID != id else { return }
        let generation = UUID()
        self.generation = generation
        errorMessage = nil
        guard let host else {
            projects = []
            worktreeURLs = []
            loadID = id
            return
        }
        do {
            let workspace = try await ProjectStore(context: context).resolveWorkspace(for: host) { path in
                do {
                    return try FileManager.default.contentsOfDirectory(
                        at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    ).filter {
                        let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        return values.isDirectory == true && values.isSymbolicLink != true
                    }.map(\.lastPathComponent)
                } catch CocoaError.fileReadNoSuchFile { return [] }
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            loadID = id
            projects = workspace.projects
            worktreeURLs = workspace.worktrees.map { URL(fileURLWithPath: $0.path) }
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            projects = []
            worktreeURLs = []
            errorMessage = error.localizedDescription
            loadID = nil
        }
    }

    func stop() {
        loadID = nil
        generation = UUID()
    }

    func resolve(_ url: URL, context: ModelContext) async throws -> URL {
        guard let project = projects.first(where: { $0.path == url.path }) else { return url }
        return URL(fileURLWithPath: try await ProjectStore(context: context).resolvePath(for: project))
    }

}
