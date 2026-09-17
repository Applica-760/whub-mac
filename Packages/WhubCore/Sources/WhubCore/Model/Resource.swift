import Foundation
import SwiftData

@Model
public class Resource {
    public var workspacePath: String
    public var gitURL: String?
    public var statusEnabled: Bool

    public var project: Project?

    init(
        workspacePath: String,
        gitURL: String? = nil,
        statusEnabled: Bool = true
    ) {
        self.workspacePath = workspacePath
        self.gitURL = gitURL
        self.statusEnabled = statusEnabled
    }
}

@available(macOS 26.0, *)
@Model
public final class LocalResource: Resource {
    public var localPath: String

    public init(
        workspacePath: String,
        localPath: String,
        gitURL: String? = nil,
        statusEnabled: Bool = true
    ) {
        self.localPath = localPath
        super.init(
            workspacePath: workspacePath,
            gitURL: gitURL,
            statusEnabled: statusEnabled
        )
    }
}

@available(macOS 26.0, *)
@Model
public final class RemoteResource: Resource {
    public var remotePath: String
    public var host: Host?

    public init(
        workspacePath: String,
        remotePath: String,
        host: Host? = nil,
        gitURL: String? = nil,
        statusEnabled: Bool = true
    ) {
        self.remotePath = remotePath
        self.host = host
        super.init(
            workspacePath: workspacePath,
            gitURL: gitURL,
            statusEnabled: statusEnabled
        )
    }
}
