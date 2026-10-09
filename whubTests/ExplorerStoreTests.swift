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
        let files = FilesStore()
        let store = files.explorer
        let connections = RemoteConnectionStore()
        store.startWatching()
        defer { store.stopWatching() }
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 0, context: context)
        #expect(store.locations.map(\.path) == [base.path, projectURL.path, firstWorktree.path])
        #expect(store.canRefresh)
        store.selectedLocation = .local(URL(fileURLWithPath: project.path))
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 0, context: context)
        let secondWorktree = base.appendingPathComponent("worktrees/app-2")
        try FileManager.default.createDirectory(at: secondWorktree, withIntermediateDirectories: true)
        await store.update(projects: [project], hosts: [host], connections: connections,
                           refreshID: 1, context: context)
        #expect(store.selectedLocation?.path == projectURL.path)
        #expect(store.rootURL?.path == projectURL.path)
        #expect(store.worktreeURLs.map(\.path) == [firstWorktree.path, secondWorktree.path])
        #expect(store.errorMessage == nil)
        #expect(files.git.rootURL?.path == projectURL.path)
        let folder = projectURL.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: projectURL.appendingPathComponent("a.swift"))
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        store.refresh()
        #expect(store.updateTree(gitChanges: [:]))
        #expect(store.rootItems.map(\.location.name) == ["src", "a.swift"])
        let item = try #require(store.rootItems.first)
        try Data().write(to: folder.appendingPathComponent("child.swift"))
        #expect(store.children(for: item).map(\.location.name) == ["child.swift"])
        store.refresh()
        #expect(store.updateTree(gitChanges: [:]))
        #expect(store.rootItems.first === item)
        store.stopWatching()
        #expect(files.git.rootURL?.path == projectURL.path)
        let refreshID = files.refreshID
        files.refresh()
        #expect(files.refreshID == refreshID + 1)
        store.selectedLocation = .local(firstWorktree)
        #expect(files.git.rootURL == nil)
    }

    @Test func remoteFileIsPreparedBeforePreviewAndOpen() async throws {
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/workspace", hostname: "unused", user: "test", identityFile: ""
        )
        let connections = RemoteConnectionStore()
        let files = FilesStore()
        let store = files.explorer
        let editor = files.editor
        await store.update(projects: [], hosts: [host], connections: connections,
                           refreshID: 0, context: container.mainContext)
        #expect(!store.canRefresh)
        let root = FileLocation.remote(hostID: host.persistentModelID, path: "/workspace/projects/app")
        store.selectedLocation = root
        let session = NSObject()
        store.remoteTree.update(source: .init(root: root, sessionID: ObjectIdentifier(session)), refreshID: 0) { _ in [] }
        defer { store.stopWatching() }
        let file = root.appending("file.swift")
        defer { editor.close(file) }
        files.preview(file, hosts: [host], connections: connections)
        #expect(editor.local.fileStores.isEmpty)
        #expect(editor.previewLocation == file)
        #expect(editor.selectedLocation == file)
        if case .disconnected = editor.remote.states[file] {} else {
            Issue.record("正しい閲覧ルートでRemote取得を準備できていません")
        }
        files.open(file, hosts: [host], connections: connections)
        #expect(editor.previewLocation == nil)
        #expect(editor.fileLocations == [file])
    }

    private func modelContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: WhubCore.Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        return container
    }
}
