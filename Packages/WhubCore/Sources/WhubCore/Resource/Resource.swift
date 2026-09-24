import SwiftData

@Model
public class Resource {
    public var gitURL: String?
    public var project: Project?

    init(gitURL: String? = nil) {
        self.gitURL = gitURL
    }
}

@available(macOS 26.0, *)
@Model
public final class LocalResource: Resource {
    public override init(gitURL: String? = nil) {
        super.init(gitURL: gitURL)
    }
}

@available(macOS 26.0, *)
@Model
public final class RemoteResource: Resource {
    public var host: Host?

    public init(host: Host? = nil, gitURL: String? = nil) {
        self.host = host
        super.init(gitURL: gitURL)
    }
}
