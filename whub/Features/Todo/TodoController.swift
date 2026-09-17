import Foundation
import SwiftData

@MainActor
final class TodoController {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func add(
        title: String,
        project: String? = nil,
        priority: String = "none",
        dueDate: Date? = nil
    ) throws -> Todo {
        let todo = Todo(title: title, project: project, priority: priority, dueDate: dueDate)
        modelContext.insert(todo)
        try modelContext.save()
        return todo
    }

    func toggleCompletion(of todo: Todo) throws {
        todo.isCompleted.toggle()
        todo.completedAt = todo.isCompleted ? .now : nil
        todo.updatedAt = .now
        try modelContext.save()
    }

    func delete(_ todo: Todo) throws {
        modelContext.delete(todo)
        try modelContext.save()
    }
}
