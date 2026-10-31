import AppKit
import Foundation
import SwiftData
import Testing
import WebKit
import WhubCore
import WhubGit
@testable import whub

@Suite @MainActor
struct ExplorerStoreTests {
    @Test func remoteDecorationsUpdateAndClearWhenRootChanges() throws {
        let container = try explorerTestModelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/workspace", hostname: "unused", user: "test", identityFile: ""
        )
        let root = FileLocation.remote(hostID: host.persistentModelID, path: "/workspace/app")
        let store = ExplorerStore()
        let session = NSObject()
        store.selectedLocation = root
        store.remoteTree.update(source: .init(root: root, sessionID: ObjectIdentifier(session)), refreshID: 0) { _ in [] }
        defer { store.stopWatching() }
        let file = root.appending("src/file.swift")
        #expect(store.updateTree(gitChanges: [:], remoteChanges: [file: .added]))
        #expect(store.decorations[file] == .added)
        #expect(store.decorations[root.appending("src")] == .added)
        #expect(!store.updateTree(gitChanges: [:], remoteChanges: [file: .added]))
        #expect(store.updateTree(gitChanges: [:], remoteChanges: [file: .modified]))
        #expect(store.decorations[file] == .modified)
        #expect(store.decorations[root.appending("src")] == .modified)
        let other = FileLocation.remote(hostID: host.persistentModelID, path: "/workspace/other")
        store.selectedLocation = other
        #expect(store.updateTree(gitChanges: [:], remoteChanges: [file: .modified]))
        #expect(store.decorations.isEmpty)
        store.remoteTree.update(source: .init(root: other, sessionID: ObjectIdentifier(session)), refreshID: 0) { _ in [] }
        let otherFile = other.appending("src/file.swift")
        #expect(store.updateTree(gitChanges: [:], remoteChanges: [otherFile: .added]))
        #expect(store.decorations[other.appending("src")] == .added)
    }

    @Test func reloadUpdatesCandidatesWithoutLosingSelection() async throws {
        let container = try explorerTestModelContainer()
        let context = container.mainContext
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("projects/app")
        let firstWorktree = base.appendingPathComponent("worktrees/app-1")
        for url in [projectURL, firstWorktree, base.appendingPathComponent("projects/unregistered")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let host = try HostStore(context: context).addLocal(name: "local", basePath: base.path)
        let project = try ProjectStore(context: context).add(name: "app", gitURL: nil, host: host)
        _ = try ProjectStore(context: context).add(name: "missing", gitURL: nil, host: host)
        let files = FilesStore()
        let store = files.explorer
        let connections = RemoteConnectionStore()
        store.startWatching()
        defer { store.stopWatching() }
        await store.update(projects: [project], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
                           refreshID: 0, context: context)
        #expect(store.locations.map(\.path) == [base.path, projectURL.path, firstWorktree.path])
        store.selectedLocation = .local(URL(fileURLWithPath: project.path))
        await store.update(projects: [project], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
                           refreshID: 0, context: context)
        let secondWorktree = base.appendingPathComponent("worktrees/app-2")
        try FileManager.default.createDirectory(at: secondWorktree, withIntermediateDirectories: true)
        await store.update(projects: [project], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
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
        let container = try explorerTestModelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/workspace", hostname: "unused", user: "test", identityFile: ""
        )
        let connections = RemoteConnectionStore()
        let files = FilesStore()
        let store = files.explorer
        await store.update(projects: [], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
                           refreshID: 0, context: container.mainContext)
        let root = FileLocation.remote(hostID: host.persistentModelID, path: "/workspace/projects/app")
        store.selectedLocation = root
        let editor = files.activeEditor
        let session = NSObject()
        store.remoteTree.update(source: .init(root: root, sessionID: ObjectIdentifier(session)), refreshID: 0) { _ in [] }
        defer { store.stopWatching() }
        let file = root.appending("file.swift")
        defer { editor.close(.file(file)) }
        files.preview(file, hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections))
        #expect(editor.local.fileStores.isEmpty)
        #expect(editor.previewTab == .file(file))
        #expect(editor.selectedTab == .file(file))
        if case .disconnected = editor.remote.states[file] {} else {
            Issue.record("正しい閲覧ルートでRemote取得を準備できていません")
        }
        files.open(file, hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections))
        #expect(editor.previewTab == nil)
        #expect(editor.tabs == [.file(file)])
    }

    @Test func storesOwnNameEditingAndCommitLifecycle() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FilesStore()
        let store = files.explorer
        store.selectedLocation = .local(directory)
        let folder = ExplorerItem(location: .local(directory), isDirectory: true)
        for operation in [ExplorerStore.NameEdit.Operation.newFile, .newFolder] {
            store.beginNameEditing(operation, item: folder, parent: nil)
            store.updateName("../invalid")
            #expect(throws: FilesStore.OperationError.self) { try files.commitName() }
            #expect(store.nameEdit?.name == "../invalid")
            let name = operation == .newFile ? "file.txt" : "folder"
            store.updateName(name)
            try files.commitName()
            #expect(store.nameEdit == nil)
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        let file = ExplorerItem(location: .local(directory.appendingPathComponent("file.txt")), isDirectory: false)
        store.beginNameEditing(.rename, item: file, parent: folder)
        store.updateName("renamed.txt")
        try files.commitName()
        #expect(store.nameEdit == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed.txt").path))
        store.beginNameEditing(.newFile, item: folder, parent: nil)
        store.selectedLocation = nil
        #expect(store.nameEdit == nil)
    }

    @Test func localMutationsProtectUnsavedTabsAndDoNotOverwrite() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FilesStore()
        files.explorer.selectedLocation = .local(directory)
        try files.create(in: directory, name: "folder", isDirectory: true)
        let folder = directory.appendingPathComponent("folder")
        try files.create(in: folder, name: "file.txt", isDirectory: false)
        let file = folder.appendingPathComponent("file.txt")
        try Data("saved".utf8).write(to: file)
        try files.rename(file, to: "File.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("File.txt"))
        try files.rename(folder.appendingPathComponent("File.txt"), to: "file.txt")
        try files.create(in: folder, name: "other.txt", isDirectory: false)
        let other = folder.appendingPathComponent("other.txt")
        try Data("other".utf8).write(to: other)
        try files.create(in: directory, name: "destination", isDirectory: true)
        let destination = directory.appendingPathComponent("destination")
        try files.create(in: destination, name: "file.txt", isDirectory: false)
        #expect(throws: (any Error).self) { try files.move(file, to: destination) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        #expect(throws: (any Error).self) { try files.rename(file, to: "other.txt") }
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        #expect(try String(contentsOf: other, encoding: .utf8) == "other")
        for name in ["", " ", ".", "..", "../outside", "a/b", "a:b", "a\n"] {
            #expect(throws: FilesStore.OperationError.self) {
                try files.create(in: folder, name: name, isDirectory: false)
            }
        }
        #expect(throws: (any Error).self) { try files.create(in: folder, name: "file.txt", isDirectory: false) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        #expect(throws: (any Error).self) { try files.create(in: directory, name: "folder", isDirectory: true) }
        let location = FileLocation.local(file)
        files.open(location, hosts: [], connections: RemoteConnectionStore(), servers: RemoteServerStore(connections: RemoteConnectionStore()))
        let editor = files.activeEditor
        let local = try #require(editor.local.fileStores[location])
        local.document.content = .text("unsaved")
        files.explorer.selectedLocation = .local(directory.appendingPathComponent("another-workspace"))
        #expect(throws: FilesStore.OperationError.self) { try files.rename(folder, to: "renamed") }
        #expect(throws: FilesStore.OperationError.self) { try files.move(folder, to: destination) }
        #expect(throws: FilesStore.OperationError.self) { try files.trash(folder) }
        #expect(editor.tabs == [.file(location)])
        #expect(local.document.hasUnsavedChanges)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try local.save()
        try files.move(other, to: destination)
        #expect(try String(contentsOf: destination.appendingPathComponent("other.txt"), encoding: .utf8) == "other")
        #expect(!FileManager.default.fileExists(atPath: other.path))
        try files.create(in: directory, name: "taken", isDirectory: true)
        #expect(throws: (any Error).self) { try files.rename(folder, to: "taken") }
        #expect(editor.tabs == [.file(location)])
        try files.rename(folder, to: "renamed")
        #expect(editor.tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let renamed = directory.appendingPathComponent("renamed/file.txt")
        #expect(try String(contentsOf: renamed, encoding: .utf8) == "unsaved")
        files.open(.local(renamed), hosts: [], connections: RemoteConnectionStore(), servers: RemoteServerStore(connections: RemoteConnectionStore()))
        let trashed = try #require(try files.trash(renamed))
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(!FileManager.default.fileExists(atPath: renamed.path))
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "unsaved")
        #expect(files.activeEditor.tabs.isEmpty)
    }
}
