import SwiftData

@Model
public class Host {
    @Attribute(.unique) public var name: String
    public var basePath: String

    init(name: String, basePath: String) {
        self.name = name
        self.basePath = basePath
    }
}

@available(macOS 26.0, *)
@Model
public final class LocalHost: Host {
    public init(basePath: String) {
        super.init(name: "local", basePath: basePath)
    }
}

@available(macOS 26.0, *)
@Model
public final class RemoteHost: Host {
    public var hostname: String
    public var user: String
    public var port: Int
    public var identityFile: String

    public init(
        name: String,
        basePath: String,
        hostname: String,
        user: String,
        port: Int = 22,
        identityFile: String
    ) {
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        super.init(name: name, basePath: basePath)
    }
}
