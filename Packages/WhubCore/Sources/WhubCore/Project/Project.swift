import Foundation
import SwiftData

@Model
public final class Project {
    @Attribute(.unique) public internal(set) var name: String
    public internal(set) var gitURL: String?
    public internal(set) var host: Host

    init(name: String, gitURL: String?, host: Host) {
        self.name = name
        self.gitURL = gitURL
        self.host = host
    }
}
