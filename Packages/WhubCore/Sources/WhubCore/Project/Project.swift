import Foundation
import SwiftData

@Model
public final class Project {
    @Attribute(.unique) public var name: String

    @Relationship(deleteRule: .cascade, inverse: \Resource.project)
    public var resource: Resource

    public init(name: String, resource: Resource) {
        self.name = name
        self.resource = resource
    }
}
