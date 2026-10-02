import Foundation
import SwiftData

public enum ActivityCategoryStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)
    case invalidTargetSeconds

    public var errorDescription: String? {
        switch self {
        case .invalidTargetSeconds:
            "Target time must be a positive, finite number of seconds."
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

    public func setGoal(
        _ category: ActivityCategory,
        kind: ActivityCategory.Goal.Kind,
        targetSeconds: TimeInterval
    ) throws {
        guard targetSeconds.isFinite, targetSeconds > 0 else {
            throw ActivityCategoryStoreError.invalidTargetSeconds
        }
        let previous = category.goal
        category.goal = ActivityCategory.Goal(kind: kind, targetSeconds: targetSeconds)
        do {
            try context.save()
        } catch {
            category.goal = previous
            throw error
        }
    }

    public func clearGoal(_ category: ActivityCategory) throws {
        let previous = category.goal
        category.goal = nil
        do {
            try context.save()
        } catch {
            category.goal = previous
            throw error
        }
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
