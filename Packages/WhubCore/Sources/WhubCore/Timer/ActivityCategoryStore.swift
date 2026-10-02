import Foundation
import SwiftData

public enum ActivityCategoryStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Activity category name is required."
        case let .duplicateName(name):
            "An activity category named \(name) already exists."
        }
    }
}

@MainActor
public struct ActivityCategoryStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func fetchCategories() throws -> [ActivityCategory] {
        try context.fetch(FetchDescriptor(sortBy: [SortDescriptor(\ActivityCategory.name)]))
    }

    @discardableResult
    public func add(name: String) throws -> ActivityCategory {
        let name = try validate(name: name)
        let category = ActivityCategory(name: name)
        context.insert(category)
        try context.save()
        return category
    }

    public func rename(_ category: ActivityCategory, name: String) throws {
        let name = try validate(name: name, excluding: category)
        category.name = name
        try context.save()
    }

    private func validate(name rawName: String, excluding category: ActivityCategory? = nil) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ActivityCategoryStoreError.nameRequired }
        guard try !fetchCategories().contains(where: {
            $0.name == name && $0.persistentModelID != category?.persistentModelID
        }) else {
            throw ActivityCategoryStoreError.duplicateName(name)
        }
        return name
    }
}
