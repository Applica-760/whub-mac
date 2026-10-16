import AppKit
import Foundation
import SwiftData
import Testing
import WebKit
import WhubCore
@testable import whub

@Suite @MainActor
struct ExplorerStoreTests {
    @Test func contextMenuTargetsClickedFileAndRestrictsDiffToLocalFiles() throws {
        let url = URL(fileURLWithPath: "/repo/src/file.swift")
        var opened: FileLocation?
        let menu = ExplorerContextMenu(location: .local(url), isDirectory: false, basePath: "/repo") { opened = $0 }
        #expect(menu.items.map { $0.isSeparatorItem ? "---" : $0.title } == ["New File", "New Folder", "---", "Copy path", "Copy relative path", "---", "View Diffs", "Rename", "Move to Trash"])
        #expect(menu.items[6].isEnabled)
        #expect(menu.items[3].representedObject as? String == url.path)
        #expect(menu.items[4].representedObject as? String == "src/file.swift")
        menu.performActionForItem(at: 6)
        #expect(opened == .local(url))
        let directory = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil) { _ in }
        #expect(!directory.items[6].isEnabled)
        #expect(!directory.items[4].isEnabled)
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = FileLocation.remote(hostID: host.persistentModelID, path: url.path)
        let remoteMenu = ExplorerContextMenu(location: remote, isDirectory: false, basePath: "/repo") { _ in }
        #expect(!remoteMenu.items[3].isEnabled)
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
        await store.update(projects: [project], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
                           refreshID: 0, context: context)
        #expect(store.locations.map(\.path) == [base.path, projectURL.path, firstWorktree.path])
        #expect(store.canRefresh)
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
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/workspace", hostname: "unused", user: "test", identityFile: ""
        )
        let connections = RemoteConnectionStore()
        let files = FilesStore()
        let store = files.explorer
        await store.update(projects: [], hosts: [host], connections: connections, servers: RemoteServerStore(connections: connections),
                           refreshID: 0, context: container.mainContext)
        #expect(!store.canRefresh)
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

    @Test func localActionsTargetClickedItemAndExcludeRemote() throws {
        let url = URL(fileURLWithPath: "/repo/page.HTML")
        var received: (ExplorerContextMenu.Action, FileLocation)?
        var edited: ExplorerStore.NameEdit.Operation?
        let menu = ExplorerContextMenu(location: .local(url), isDirectory: false, basePath: "/repo",
            onEdit: { edited = $0 }, onAction: { received = ($0, $1) }, onShowDiff: { _ in })
        #expect(menu.items.map { $0.isSeparatorItem ? "---" : $0.title } == ["New File", "New Folder", "---", "Copy path", "Copy relative path", "---", "View Diffs", "Rename", "Move to Trash", "Open in Browser"])
        for action in [ExplorerContextMenu.Action.trash, .openInBrowser] {
            let index = try #require(menu.items.firstIndex { $0.title == action.rawValue })
            menu.performActionForItem(at: index)
            #expect(received?.0 == action)
            #expect(received?.1 == .local(url))
        }
        for operation in [ExplorerStore.NameEdit.Operation.newFile, .newFolder, .rename] {
            let index = try #require(menu.items.firstIndex { $0.title == operation.title })
            menu.performActionForItem(at: index)
            #expect(edited == operation)
        }
        let folder = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil, onShowDiff: { _ in })
        #expect(!folder.items.contains { $0.title == ExplorerContextMenu.Action.openInBrowser.rawValue })
        let blocked = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil,
                                          allowsActions: false, onShowDiff: { _ in })
        #expect(blocked.items.count == 4)
        let container = try modelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = ExplorerContextMenu(location: .remote(hostID: host.persistentModelID, path: url.path),
                                         isDirectory: false, basePath: nil, onShowDiff: { _ in })
        #expect(remote.items.count == 4)
    }

    @Test func inlineNamesUseChildRowsAndPreserveFailedInput() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        let folder = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("existing.txt"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExplorerStore()
        store.selectedLocation = .local(directory)
        store.localTree.setRoot(directory)
        let coordinator = ExplorerOutlineView.Coordinator(store: store, onFilePreview: { _ in }, onFileOpen: { _ in })
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        coordinator.update(basePath: nil, gitChanges: [:])
        let parent = try #require(store.rootItems.first)
        for action in [ExplorerStore.NameEdit.Operation.newFile, .newFolder] {
            coordinator.beginEditing(action, item: parent)
            let edit = try #require(store.nameEdit)
            #expect(edit.target.path == folder.path)
            #expect(edit.parent === parent)
            #expect(outline.isItemExpanded(parent))
            #expect(outline.parent(forItem: edit.item) as? ExplorerItem === parent)
            #expect(edit.item.isDirectory == (action == .newFolder))
            #expect(!FileManager.default.fileExists(atPath: edit.item.location.path))
            coordinator.onCommitName = { throw FilesStore.OperationError.invalidName }
            #expect(throws: FilesStore.OperationError.self) { try coordinator.commitName("../bad") }
            #expect(store.nameEdit?.name == "../bad")
            coordinator.cancelEditing()
            #expect(store.nameEdit == nil)
            #expect(outline.numberOfRows == 2)
        }
        let existing = try #require(store.children(for: parent).first)
        coordinator.beginEditing(.newFile, item: existing)
        #expect(store.nameEdit?.target.path == folder.path)
        coordinator.cancelEditing()
        coordinator.beginEditing(.rename, item: existing)
        #expect(store.nameEdit?.item === existing)
        #expect(store.nameEdit?.name == "existing.txt")
        var committed = false
        coordinator.onCommitName = {
            let edit = try #require(store.nameEdit)
            #expect(edit.operation == .rename)
            #expect(edit.target == folder.appendingPathComponent("existing.txt"))
            #expect(edit.name == "renamed.txt")
            committed = true
            store.cancelNameEditing()
        }
        try coordinator.commitName("renamed.txt")
        #expect(committed)
        #expect(store.nameEdit == nil)
        store.beginNameEditing(.newFile, item: parent, parent: nil)
        coordinator.update(basePath: nil, gitChanges: [:])
        let externalEdit = try #require(store.nameEdit)
        #expect(outline.row(forItem: externalEdit.item) >= 0)
        store.cancelNameEditing()
        coordinator.update(basePath: nil, gitChanges: [:])
        #expect(outline.row(forItem: externalEdit.item) == -1)
        coordinator.beginEditing(.newFile, item: parent)
        store.selectedLocation = .local(folder)
        coordinator.update(basePath: nil, gitChanges: [:])
        #expect(store.nameEdit == nil)
    }

    @Test func storesOwnNameEditingAndCommitLifecycle() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
        #expect(throws: FilesStore.OperationError.self) { try files.trash(folder) }
        #expect(editor.tabs == [.file(location)])
        #expect(local.document.hasUnsavedChanges)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try local.save()
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

    @Test func browserConsumesOnlyUnhandledPlainArrowsFromVisibleWebContent() throws {
        final class KeyReceiver: NSResponder {
            var count = 0
            override func keyDown(with event: NSEvent) { count += 1 }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = BrowserContainerView(frame: window.contentView!.bounds)
        window.contentView = container
        let webView = WKWebView(frame: container.bounds)
        container.addSubview(webView)
        #expect(window.makeFirstResponder(webView))
        let receiver = KeyReceiver()
        container.nextResponder = receiver

        func send(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeatKey, keyCode: keyCode))
            container.keyDown(with: event)
        }

        for key in UInt16(123)...126 {
            try send(key)
            try send(key, modifiers: [.function, .numericPad], repeatKey: true)
        }
        #expect(receiver.count == 0)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            try send(125, modifiers: modifier)
        }
        try send(0)
        #expect(receiver.count == 5)

        webView.isHidden = true
        try send(125)
        #expect(receiver.count == 6)
        webView.isHidden = false
        let input = NSTextView(frame: container.bounds)
        container.addSubview(input)
        #expect(window.makeFirstResponder(input))
        try send(125)
        #expect(receiver.count == 7)
    }

    @Test func browserLoadsLocalHTMLAndRelativeResources() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local page.html")
        try Data("<title>Local HTML</title><link rel='stylesheet' href='style.css'><body><img src='icon.svg'></body>".utf8).write(to: url)
        try Data("body { color: rgb(1, 2, 3); }".utf8).write(to: directory.appendingPathComponent("style.css"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'></svg>".utf8).write(to: directory.appendingPathComponent("icon.svg"))
        let browser = BrowserStore()
        let firstID = browser.selectedSessionID
        browser.open(url)
        #expect(browser.sessions.count == 2)
        #expect(browser.selectedSessionID != firstID)
        #expect(!browser.selectedSession.showsBookmarks)
        #expect(BrowserStore.url(from: url.absoluteString) == url)
        #expect(BrowserStore.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(BrowserStore.url(from: "javascript://alert(1)") == nil)
        let page = browser.selectedSession.page
        let deadline = ContinuousClock.now + .seconds(15)
        while page.isLoading || page.title != "Local HTML" {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await page.callJavaScript("return getComputedStyle(document.body).color") as? String == "rgb(1, 2, 3)")
        #expect(try await page.callJavaScript("return document.images[0].naturalWidth") as? Int == 12)
        #expect(browser.selectedSession.address == url.absoluteString)
    }

    private func modelContainer() throws -> ModelContainer {
        let container = try ModelContainer(for: WhubCore.Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        return container
    }
}
