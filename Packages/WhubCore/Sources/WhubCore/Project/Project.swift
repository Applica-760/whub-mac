import Foundation
import SwiftData

@Model
public final class Project {
    @Attribute(.unique) public var name: String
    public var gitURL: String?
    public var host: Host

    public init(name: String, gitURL: String?, host: Host) {
        self.name = name
        self.gitURL = gitURL
        self.host = host
    }
}
