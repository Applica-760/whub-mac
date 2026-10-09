import Foundation
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct ExplorerStoreTests {
    @Test func reloadUpdatesCandidatesWithoutLosingSelection() async throws {
        let container = try modelContainer()
        let context = container.mainContext
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("projects/app")
        let firstWorktree = base.appendingPathComponent("worktrees/app-1")
        for url in [projectURL, firstWorktree] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let host = try HostStore(context: context).addLocal(name: "local", basePath: base.path)
        let project = try ProjectStore(context: context).add(name: "app", gitURL: nil, host: host)
        let store = ExplorerStore()
        let git = GitStore()
        let connections = RemoteConnectionStore()
        store.startWatching(gitStore: git)
        defer { store.stopWatching() }
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 0, context: context, gitStore: git)
        #expect(store.locations.map(\.path) == [base.path, projectURL.path, firstWorktree.path])
        #expect(store.canRefresh)
        store.selectedLocation = .local(URL(fileURLWithPath: project.path))
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 0, context: context, gitStore: git)
        let secondWorktree = base.appendingPathComponent("worktrees/app-2")
        try FileManager.default.createDirectory(at: secondWorktree, withIntermediateDirectories: true)
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 1, context: context, gitStore: git)
        #expect(store.selectedLocation?.path == projectURL.path)
        #expect(store.rootURL?.path == projectURL.path)
        #expect(store.worktreeURLs.map(\.path) == [firstWorktree.path, secondWorktree.path])
        #expect(store.errorMessage == nil)
    }

    @Test func remoteFileIsPreparedBeforePreviewAndOpen() async throws {
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/workspace", hostname: "unused", user: "test", identityFile: ""
        )
        let connections = RemoteConnectionStore()
        let store = ExplorerStore()
        let viewer = FileViewerStore()
        let git = GitStore()
        await store.update(projects: [], hosts: [host], connections: connections,
                           refreshID: 0, context: container.mainContext, gitStore: git)
        #expect(!store.canRefresh)
        let root = FileLocation.remote(hostID: host.persistentModelID, path: "/workspace/projects/app")
        store.selectedLocation = root
        let session = NSObject()
        store.remoteTree.update(source: .init(root: root, sessionID: ObjectIdentifier(session)), refreshID: 0) { _ in [] }
        defer { store.stopWatching() }
        let file = root.appending("file.swift")
        defer { viewer.close(file) }
        store.preview(file, viewer: viewer, connections: connections)
        #expect(viewer.previewLocation == file)
        #expect(viewer.selectedLocation == file)
        if case .disconnected = viewer.remote.states[file] {} else {
            Issue.record("正しい閲覧ルートでRemote取得を準備できていません")
        }
        store.open(file, viewer: viewer, connections: connections)
        #expect(viewer.previewLocation == nil)
        #expect(viewer.fileLocations == [file])
    }

    private func modelContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: WhubCore.Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        return container
    }
}
