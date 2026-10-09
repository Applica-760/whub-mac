import Foundation
import SwiftData
import WhubCore

@MainActor
final class LocalWorkspaceStore {
    private(set) var projects: [Project] = []
    private(set) var basePath: String?
    private(set) var worktreeURLs: [URL] = []
    private var loadID: LoadID?

    struct LoadID: Equatable {
        let projectPaths: [String]
        let worktreePaths: [String]
        let refreshID: Int
    }

    func update(projects: [Project], basePath: String?, id: LoadID) {
        self.projects = projects.filter { $0.host is LocalHost }
        self.basePath = basePath
        if loadID != id {
            loadID = id
            loadWorktrees(projects: self.projects)
        }
    }

    func stop() { loadID = nil }

    func resolve(_ url: URL, context: ModelContext) async throws -> URL {
        guard let project = projects.first(where: { $0.path == url.path }) else { return url }
        return URL(fileURLWithPath: try await ProjectStore(context: context).resolvePath(for: project))
    }

    private func loadWorktrees(projects: [Project]) {
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
