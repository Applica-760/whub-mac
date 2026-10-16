import Foundation
import SwiftData

public enum ProjectStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)
    case invalidName
    case directoryNotFound(String)
    case remoteCheckFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Project name is required."
        case let .duplicateName(name):
            "A project named \(name) already exists on this host."
        case .invalidName:
            "Project name must be one directory name."
        case let .directoryNotFound(path):
            "Project directory was not found: \(path)"
        case let .remoteCheckFailed(name):
            "Could not check the project directory on host \(name)."
        }
    }
}

@MainActor
public struct ProjectStore {
    public struct Workspace {
        public let projects: [Project]
        public let worktrees: [Worktree]
    }

    public struct Worktree {
        public let project: Project
        public let issueNumber: Int
        public let path: String
    }

    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchProjects() throws -> [Project] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\Project.name)]))
    }

    /// The loader returns immediate directory names only; retrieval failures must throw.
    public func resolveWorkspace(
        for host: Host,
        listDirectories: (String) async throws -> [String]
    ) async throws -> Workspace {
        let registered = try fetchProjects().filter { $0.host.persistentModelID == host.persistentModelID }
        guard !registered.isEmpty else { return Workspace(projects: [], worktrees: []) }

        let projectNames = Set(try await listDirectories(host.projectsPath))
        let projects = registered.filter { projectNames.contains($0.name) }
        let worktreeNames = try await listDirectories(host.worktreesPath)
        var worktrees: [Worktree] = []
        for name in Set(worktreeNames) {
            let path = (host.worktreesPath as NSString).appendingPathComponent(name)
            for project in registered {
                if let number = project.worktreeIssueNumber(for: path) {
                    worktrees.append(Worktree(project: project, issueNumber: number, path: path))
                    break
                }
            }
        }
        worktrees.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return Workspace(projects: projects, worktrees: worktrees)
    }

    @discardableResult
    public func add(name: String, gitURL: String?, host: Host) throws -> Project {
        let name = try validate(name: name, host: host)
        let project = Project(name: name, gitURL: gitURL, host: host)
        context.insert(project)
        try context.save()
        return project
    }

    public func edit(_ project: Project, name: String, gitURL: String?, host: Host) throws {
        let name = try validate(name: name, host: host, excluding: project)
        project.name = name
        project.gitURL = gitURL
        project.host = host
        try context.save()
    }

    public func resolvePath(for project: Project, connection: SSHConnectionService? = nil) async throws -> String {
        let path = project.path

        if let remote = project.host as? RemoteHost {
            let configuration = try SSH.Configuration(hostname: remote.hostname, user: remote.user,
                                                      port: remote.port, identityFile: remote.identityFile)
            guard let connection, connection.configuration == configuration else {
                throw ProjectStoreError.remoteCheckFailed(remote.name)
            }
            let status = try await connection.run(["test", "-d", path])
            guard status == 0 else {
                if status == 1 { throw ProjectStoreError.directoryNotFound(path) }
                throw ProjectStoreError.remoteCheckFailed(remote.name)
            }
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProjectStoreError.directoryNotFound(path)
            }
        }
        return path
    }

    private func validate(name rawName: String, host: Host, excluding project: Project? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectStoreError.nameRequired }
        guard name != ".", name != "..", !name.contains("/") else {
            throw ProjectStoreError.invalidName
        }
        guard try !fetchProjects().contains(where: {
            $0.host.persistentModelID == host.persistentModelID
                && $0.name == name && $0.persistentModelID != project?.persistentModelID
        }) else {
            throw ProjectStoreError.duplicateName(name)
        }
        return name
    }

    public func delete(_ project: Project) throws {
        context.delete(project)
        try context.save()
    }
}
