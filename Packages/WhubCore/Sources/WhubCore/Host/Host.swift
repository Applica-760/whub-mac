import SwiftData

@Model
public class Host {
    @Attribute(.unique) public internal(set) var name: String
    public internal(set) var basePath: String

    init(name: String, basePath: String) {
        self.name = name
        self.basePath = basePath
    }
}

@available(macOS 26.0, *)
@Model
public final class LocalHost: Host {
    override init(name: String, basePath: String) {
        super.init(name: name, basePath: basePath)
    }
}

@available(macOS 26.0, *)
@Model
public final class RemoteHost: Host {
    public internal(set) var hostname: String
    public internal(set) var user: String
    public internal(set) var port: Int
    public internal(set) var identityFile: String

    init(
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
