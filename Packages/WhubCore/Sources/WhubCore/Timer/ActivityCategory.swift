import Foundation
import SwiftData

@Model
public final class ActivityCategory {
    public struct Goal: Codable {
        public enum Kind: String, Codable {
            case average
            case total
        }

        public let kind: Kind
        public let targetSeconds: TimeInterval
    }

    @Attribute(.unique) public internal(set) var id: UUID
    public internal(set) var name: String
    public internal(set) var goal: Goal? = nil

    init(name: String) {
        id = UUID()
        self.name = name
    }
}
