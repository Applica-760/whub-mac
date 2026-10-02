import Foundation
import SwiftData

public enum ActivityCategoryStoreError: LocalizedError {
    case nameRequired
    case duplicateName(String)
    case invalidTargetSeconds
    case invalidColor

    public var errorDescription: String? {
        switch self {
        case .invalidColor:
            "Color must be a 24-bit RGB value."
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
    public func add(name: String, colorRGB: Int = 0x007AFF) throws -> ActivityCategory {
        let name = try validate(name: name)
        try validate(colorRGB: colorRGB)
        let category = ActivityCategory(name: name, colorRGB: colorRGB)
        context.insert(category)
        try context.save()
        return category
    }

    public func rename(_ category: ActivityCategory, name: String) throws {
        try edit(category, name: name, colorRGB: category.colorRGB)
    }

    public func edit(_ category: ActivityCategory, name: String, colorRGB: Int) throws {
        let name = try validate(name: name, excluding: category)
        try validate(colorRGB: colorRGB)
        let previous = (category.name, category.colorRGB)
        category.name = name
        category.colorRGB = colorRGB
        do {
            try context.save()
        } catch {
            category.name = previous.0
            category.colorRGB = previous.1
            throw error
        }
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

    private func validate(colorRGB: Int) throws {
        guard (0...0xFFFFFF).contains(colorRGB) else {
            throw ActivityCategoryStoreError.invalidColor
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
