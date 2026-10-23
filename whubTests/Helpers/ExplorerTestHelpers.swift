import SwiftData
import WhubCore

@MainActor
func explorerTestModelContainer() throws -> ModelContainer {
    let container = try ModelContainer(for: WhubCore.Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    container.mainContext.autosaveEnabled = false
    return container
}
