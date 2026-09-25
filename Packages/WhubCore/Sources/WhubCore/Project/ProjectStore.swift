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
            "A project named \(name) already exists."
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
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchProjects() throws -> [Project] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\Project.name)]))
    }

    @discardableResult
    public func add(name: String, gitURL: String?, host: Host) throws -> Project {
        let name = try validate(name: name)
        let project = Project(name: name, gitURL: gitURL, host: host)
        context.insert(project)
        try context.save()
        return project
    }

    public func edit(_ project: Project, name: String, gitURL: String?, host: Host) throws {
        let name = try validate(name: name, excluding: project)
        project.name = name
        project.gitURL = gitURL
        project.host = host
        try context.save()
    }

    public func resolvePath(for project: Project) async throws -> String {
        let projectsPath = (project.host.basePath as NSString).appendingPathComponent("projects")
        let path = (projectsPath as NSString).appendingPathComponent(project.name)

        if let remote = project.host as? RemoteHost {
            let status = try await SSH.run(["test", "-d", path], on: remote)
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

    private func validate(name rawName: String, excluding project: Project? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectStoreError.nameRequired }
        guard name != ".", name != "..", !name.contains("/") else {
            throw ProjectStoreError.invalidName
        }
        guard try !fetchProjects().contains(where: {
            $0.name == name && $0.persistentModelID != project?.persistentModelID
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
