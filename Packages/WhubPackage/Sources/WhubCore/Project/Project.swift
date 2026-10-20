import Foundation
import SwiftData

@Model
public final class Project {
    #Unique<Project>([\.host, \.name])

    public internal(set) var name: String
    public internal(set) var gitURL: String?
    public internal(set) var host: Host
    public internal(set) var isVisibleInExplorer: Bool = true

    init(name: String, gitURL: String?, host: Host) {
        self.name = name
        self.gitURL = gitURL
        self.host = host
    }

    public var path: String {
        (host.projectsPath as NSString).appendingPathComponent(name)
    }

    public func worktreePath(issueNumber: Int) -> String {
        (host.worktreesPath as NSString).appendingPathComponent("\(name)-\(issueNumber)")
    }

    public func worktreeIssueNumber(for path: String) -> Int? {
        let directoryName = (path as NSString).lastPathComponent
        let prefix = name + "-"
        guard directoryName.hasPrefix(prefix),
              let number = Int(directoryName.dropFirst(prefix.count)), number > 0,
              path == worktreePath(issueNumber: number) else { return nil }
        return number
    }
}
