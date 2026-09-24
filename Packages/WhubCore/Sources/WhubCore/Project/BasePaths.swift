import SwiftData

@Model
public final class BasePaths {
    public var projectRoot: String
    public var worktreeRoot: String
    public var host: Host?

    public init(projectRoot: String, worktreeRoot: String, host: Host? = nil) {
        self.projectRoot = projectRoot
        self.worktreeRoot = worktreeRoot
        self.host = host
    }
}
