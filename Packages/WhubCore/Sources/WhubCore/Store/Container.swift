import Foundation
import SwiftData

public enum Container {
    public static let url: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("whub", isDirectory: true)
        .appendingPathComponent("workspace.store")
    }()

    public static func make() throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let configuration = ModelConfiguration(
            "WhubWorkspace",
            url: url,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: Host.self,
            Resource.self,
            LocalResource.self,
            RemoteResource.self,
            Project.self,
            configurations: configuration
        )
    }
}
