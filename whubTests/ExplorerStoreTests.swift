import AppKit
import Foundation
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct ExplorerStoreTests {
    @Test func contextMenuTargetsClickedFileAndRestrictsDiffToLocalFiles() throws {
        let url = URL(fileURLWithPath: "/repo/src/file.swift")
        var opened: FileLocation?
        let menu = ExplorerContextMenu(location: .local(url), isDirectory: false, basePath: "/repo") { opened = $0 }
        #expect(menu.items.map(\.title) == ["Copy path", "Copy relative path", "View Diffs"])
        #expect(menu.items[2].isEnabled)
        #expect(menu.items[0].representedObject as? String == url.path)
        #expect(menu.items[1].representedObject as? String == "src/file.swift")
        menu.performActionForItem(at: 2)
        #expect(opened == .local(url))
        let directory = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil) { _ in }
        #expect(!directory.items[2].isEnabled)
        #expect(!directory.items[1].isEnabled)
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = FileLocation.remote(hostID: host.persistentModelID, path: url.path)
        let remoteMenu = ExplorerContextMenu(location: remote, isDirectory: false, basePath: "/repo") { _ in }
        #expect(!remoteMenu.items[2].isEnabled)
        let explorer = ExplorerStore()
        explorer.selectedLocation = .local(url.deletingLastPathComponent())
        explorer.showsDiff = true
        explorer.selectedLocation = remote
        #expect(!explorer.showsDiff)
    }

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
        defer { editor.close(.file(file)) }
        files.preview(file, hosts: [host], connections: connections)
        #expect(editor.local.fileStores.isEmpty)
        #expect(editor.previewTab == .file(file))
        #expect(editor.selectedTab == .file(file))
        if case .disconnected = editor.remote.states[file] {} else {
            Issue.record("正しい閲覧ルートでRemote取得を準備できていません")
        }
        files.open(file, hosts: [host], connections: connections)
        #expect(editor.previewTab == nil)
        #expect(editor.tabs == [.file(file)])
    }

    @Test func eachOutlineRendersSharedTreeUpdates() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("first.swift"))
        let store = ExplorerStore()
        store.selectedLocation = .local(directory)
        store.localTree.setRoot(directory)
        let first = ExplorerOutlineView.Coordinator(store: store, onFilePreview: { _ in }, onFileOpen: { _ in })
        let second = ExplorerOutlineView.Coordinator(store: store, onFilePreview: { _ in }, onFileOpen: { _ in })
        let outlines = [NSOutlineView(), NSOutlineView()]
        for (coordinator, outline) in zip([first, second], outlines) {
            outline.addTableColumn(NSTableColumn(identifier: .init("name")))
            outline.dataSource = coordinator
            outline.delegate = coordinator
            coordinator.outlineView = outline
            coordinator.update(basePath: nil, gitChanges: [:])
            #expect(outline.numberOfRows == 1)
        }
        try Data().write(to: directory.appendingPathComponent("second.swift"))
        store.refresh()
        first.update(basePath: nil, gitChanges: [:])
        second.update(basePath: nil, gitChanges: [:])
        #expect(outlines.allSatisfy { $0.numberOfRows == 2 })
        // A recreated outline must render even when the shared data is already current.
        let recreated = ExplorerOutlineView.Coordinator(store: store, onFilePreview: { _ in }, onFileOpen: { _ in })
        let outline = NSOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: .init("name")))
        outline.dataSource = recreated
        outline.delegate = recreated
        recreated.outlineView = outline
        recreated.update(basePath: nil, gitChanges: [:])
        #expect(outline.numberOfRows == 2)
    }

    private func modelContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: WhubCore.Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        return container
    }
}
