import Foundation
import SwiftData

@Model
public final class TimerNotification {
    @Attribute(.unique) public internal(set) var id: UUID
    public internal(set) var name: String
    public internal(set) var hour: Int
    public internal(set) var minute: Int

    init(name: String, hour: Int, minute: Int) {
        id = UUID()
        self.name = name
        self.hour = hour
        self.minute = minute
    }
}
