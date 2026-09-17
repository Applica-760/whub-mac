import Foundation
import SwiftData

@Model
final class Todo {
    var id: UUID
    var title: String
    var project: String?
    var priority: String
    var isCompleted: Bool
    var dueDate: Date?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(title: String, project: String? = nil, priority: String = "none", dueDate: Date? = nil) {
        let now = Date()

        id = UUID()
        self.title = title
        self.project = project
        self.priority = priority
        isCompleted = false
        self.dueDate = dueDate
        completedAt = nil
        createdAt = now
        updatedAt = now
    }
}
