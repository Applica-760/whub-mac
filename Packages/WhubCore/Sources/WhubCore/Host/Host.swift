import Foundation
import SwiftData

@Model
public final class Host {
    @Attribute(.unique) public var name: String
    public var hostname: String
    public var user: String
    public var port: Int
    public var identityFile: String
    public var mountRoot: String

    @Relationship(inverse: \RemoteResource.host) public var resources: [RemoteResource] = []

    public init(
        name: String,
        hostname: String,
        user: String,
        port: Int = 22,
        identityFile: String,
        mountRoot: String
    ) {
        self.name = name
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.mountRoot = mountRoot
    }
}
