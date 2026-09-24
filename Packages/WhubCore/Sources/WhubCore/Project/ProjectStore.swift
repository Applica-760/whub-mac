import Foundation
import SwiftData

public enum ProjectStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Project name is required."
        case let .duplicateName(name):
            "A project named \(name) already exists."
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
    public func add(name: String, resource: Resource) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectStoreError.nameRequired }
        let projects = try fetchProjects()
        guard !projects.contains(where: { $0.name == name }) else {
            throw ProjectStoreError.duplicateName(name)
        }

        let project = Project(name: name, resource: resource)
        context.insert(project)
        try context.save()
        return project
    }

    public func delete(_ project: Project) throws {
        context.delete(project)
        try context.save()
    }
}
