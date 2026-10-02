import Foundation
import SwiftData

@Model
public final class TimeGoal {
    public enum Period: String, Codable {
        case day
        case week
    }

    @Attribute(.unique) public internal(set) var id: UUID
    public internal(set) var category: ActivityCategory
    public internal(set) var period: Period
    /// Target duration in seconds.
    public internal(set) var targetDuration: TimeInterval

    init(category: ActivityCategory, period: Period, targetDuration: TimeInterval) {
        id = UUID()
        self.category = category
        self.period = period
        self.targetDuration = targetDuration
    }
}
