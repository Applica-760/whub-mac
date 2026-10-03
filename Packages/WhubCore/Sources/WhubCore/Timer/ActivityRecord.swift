import Foundation
import SwiftData

@Model
public final class ActivityRecord {
    @Attribute(.unique) public internal(set) var id: UUID
    public internal(set) var category: ActivityCategory
    public internal(set) var startedAt: Date
    public internal(set) var endedAt: Date?

    init(category: ActivityCategory, startedAt: Date, endedAt: Date? = nil) {
        id = UUID()
        self.category = category
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
