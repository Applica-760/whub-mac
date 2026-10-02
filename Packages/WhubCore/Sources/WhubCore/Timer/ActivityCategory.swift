import Foundation
import SwiftData

@Model
public final class ActivityCategory {
    @Attribute(.unique) public internal(set) var id: UUID
    public internal(set) var name: String

    init(name: String) {
        id = UUID()
        self.name = name
    }
}
