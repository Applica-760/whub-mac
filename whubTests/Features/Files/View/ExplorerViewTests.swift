import AppKit
import Foundation
import SwiftData
import Testing
import WebKit
import WhubCore
@testable import whub

@Suite @MainActor
struct ExplorerViewTests {
    @Test func tabMenuShowsOnlyFileActions() {
        let markdown = FileLocation.local(URL(fileURLWithPath: "/repo/readme.md"))
        var preview: FileLocation?
        var diff: FileLocation?
        let menu = ExplorerContextMenu(location: markdown, isDirectory: false, basePath: "/repo", tabMenu: true,
                                       onAction: { action, location in if case .showPreview = action { preview = location } },
                                       onShowDiff: { diff = $0 })
        #expect(menu.items.map { $0.isSeparatorItem ? "---" : $0.title } == ["Copy path", "Copy relative path", "---", "View Diffs", "Show Preview"])
        menu.performActionForItem(at: 0)
        #expect(NSPasteboard.general.string(forType: .string) == markdown.path)
        menu.performActionForItem(at: 3)
        menu.performActionForItem(at: 4)
        #expect(diff == markdown)
        #expect(preview == markdown)
        menu.performActionForItem(at: 1)
        #expect(NSPasteboard.general.string(forType: .string) == "readme.md")
        let html = ExplorerContextMenu(location: .local(URL(fileURLWithPath: "/repo/index.html")),
                                       isDirectory: false, basePath: nil, tabMenu: true, onShowDiff: { _ in })
        #expect(html.items.map { $0.isSeparatorItem ? "---" : $0.title } == ["Copy path", "Copy relative path", "---", "View Diffs"])
        #expect(!html.items[1].isEnabled)
    }
    @Test func contextSelectionDoesNotPreviewClickedFile() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        let folder = directory.appendingPathComponent("folder")
        let file = folder.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExplorerStore()
        store.selectedLocation = .local(directory)
        store.localTree.setRoot(directory)
        var previews = 0
        let coordinator = ExplorerOutlineView.Coordinator(store: store, onFilePreview: { _ in previews += 1 }, onFileOpen: { _ in })
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outlineView = outline
        coordinator.update(basePath: nil, gitChanges: [:])
        let parent = try #require(store.rootItems.first)
        coordinator.selectContextRow(outline.row(forItem: parent), in: outline)
        #expect(outline.selectedRow == outline.row(forItem: parent))
        #expect(previews == 0)
    }
    @Test func explorerColumnScrollsWholeRowsAndShrinksWithContent() throws {
        final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
            func numberOfRows(in tableView: NSTableView) -> Int { 2 }
            func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
                let cell = ExplorerItemView(identifier: .init("file"))
                cell.textField?.stringValue = String(repeating: "long-file-name", count: 20)
                return cell
            }
        }
        let rows = Rows()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        let table = NSTableView()
        table.dataSource = rows
        table.delegate = rows
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        table.reloadData()
        let cell = ExplorerItemView(identifier: .init("file"))
        cell.textField?.stringValue = String(repeating: "long-file-name", count: 20)
        table.fitExplorerColumn(to: cell.requiredWidth)
        scroll.layoutSubtreeIfNeeded()
        #expect(table.tableColumns[0].width >= cell.requiredWidth)
        #expect(table.bounds.width > scroll.contentSize.width)
        let rendered = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ExplorerItemView)
        rendered.layoutSubtreeIfNeeded()
        let name = try #require(rendered.textField)
        #expect(name.frame.width >= name.intrinsicContentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        #expect(scroll.contentView.bounds.origin.x == 100)
        table.fitExplorerColumn(to: 80)
        scroll.layoutSubtreeIfNeeded()
        #expect(table.frame.width >= scroll.contentSize.width)
        #expect(table.tableColumns[0].width < cell.requiredWidth)
        scroll.setFrameSize(NSSize(width: 480, height: 200))
        scroll.layoutSubtreeIfNeeded()
        #expect(table.frame.width >= scroll.contentSize.width)
    }

    @Test func markdownPreviewMenuTargetsOnlyAvailableLocalMarkdownFiles() throws {
        let url = URL(fileURLWithPath: "/repo/notes.MD")
        var received: (ExplorerContextMenu.Action, FileLocation)?
        let menu = ExplorerContextMenu(location: .local(url), isDirectory: false, basePath: "/repo",
            onAction: { received = ($0, $1) }, onShowDiff: { _ in })
        let index = try #require(menu.items.firstIndex { $0.title == "Show Preview" })
        #expect(index == menu.items.count - 1)
        menu.performActionForItem(at: index)
        #expect(received?.0 == .showPreview && received?.1 == .local(url))
        for (path, directory, allowed) in [("/repo/page.html", false, true), ("/repo/notes.md", true, true),
                                            ("/repo/notes.md", false, false)] {
            let other = ExplorerContextMenu(location: .local(URL(fileURLWithPath: path)), isDirectory: directory,
                                            basePath: "/repo", allowsActions: allowed, onShowDiff: { _ in })
            #expect(!other.items.contains { $0.title == "Show Preview" })
        }
        let container = try explorerTestModelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = ExplorerContextMenu(location: .remote(hostID: host.persistentModelID, path: url.path),
                                         isDirectory: false, basePath: "/repo", onShowDiff: { _ in })
        #expect(!remote.items.contains { $0.title == "Show Preview" })
    }

    @Test func explorerKeysMoveSelectionOpenAndLeaveTextEditingAlone() throws {
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 4 }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let table = NSTableView(frame: window.contentView!.bounds)
        let rows = Rows()
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.dataSource = rows
        window.contentView?.addSubview(table)
        table.reloadData()
        #expect(window.makeFirstResponder(table))
        var opened = 0
        func send(_ key: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            return table.handleExplorerNavigation(event, canSelect: { $0 != 1 }, open: { opened += 1 })
        }
        #expect(try send("j"))
        #expect(table.selectedRow == 0)
        #expect(try send("j"))
        #expect(table.selectedRow == 2)
        #expect(try send("k"))
        #expect(table.selectedRow == 0)
        #expect(try send("k"))
        #expect(table.selectedRow == 0)
        #expect(try send("\r", code: 36))
        #expect(opened == 1)
        #expect(window.firstResponder === table)
        #expect(try !send("j", modifiers: .command))
        let input = NSTextView(frame: .zero)
        window.contentView?.addSubview(input)
        #expect(window.makeFirstResponder(input))
        #expect(try !send("j"))
        #expect(try !send("\r", code: 36))
        #expect(opened == 1)
    }

    @Test func explorerFocusReturnsToEditorBodyAndPreservesCursor() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 300))
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        window.contentView?.addSubview(content)
        window.contentView?.addSubview(sidebar)
        let header = NSTextView(frame: NSRect(x: 0, y: 250, width: 300, height: 50))
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
        editor.string = "cursor position"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        content.addSubview(header)
        content.addSubview(editor)
        let table = NSTableView(frame: sidebar.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        sidebar.addSubview(table)
        let focus = ExplorerFocusNavigation()
        focus.sidebar.view = sidebar
        focus.content.view = content
        focus.list = table
        #expect(window.makeFirstResponder(header))
        focus.toggle(prefersEditor: true)
        #expect(window.firstResponder === table)
        focus.toggle(prefersEditor: true)
        #expect(window.firstResponder === editor)
        focus.toggle(prefersEditor: true)
        focus.toggle(prefersEditor: true)
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test func contextMenuTargetsClickedFileAndRestrictsDiffToLocalFiles() throws {
        let url = URL(fileURLWithPath: "/repo/src/file.swift")
        var opened: FileLocation?
        let menu = ExplorerContextMenu(location: .local(url), isDirectory: false, basePath: "/repo") { opened = $0 }
        #expect(menu.items.map { $0.isSeparatorItem ? "---" : $0.title } == ["New File", "New Folder", "---", "Copy path", "Copy relative path", "---", "View Diffs", "Rename", "Move to Trash"])
        #expect(menu.items[6].isEnabled)
        menu.performActionForItem(at: 3)
        #expect(NSPasteboard.general.string(forType: .string) == url.path)
        menu.performActionForItem(at: 4)
        #expect(NSPasteboard.general.string(forType: .string) == "src/file.swift")
        menu.performActionForItem(at: 6)
        #expect(opened == .local(url))
        let directory = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil) { _ in }
        #expect(!directory.items[6].isEnabled)
        #expect(!directory.items[4].isEnabled)
        let container = try explorerTestModelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = FileLocation.remote(hostID: host.persistentModelID, path: url.path)
        let remoteMenu = ExplorerContextMenu(location: remote, isDirectory: false, basePath: "/repo") { _ in }
        #expect(!remoteMenu.items[3].isEnabled)
        let explorer = ExplorerStore()
        explorer.selectedLocation = .local(url.deletingLastPathComponent())
        explorer.showsDiff = true
        explorer.selectedLocation = remote
        #expect(explorer.showsDiff)
    }

    @Test func eachOutlineRendersSharedTreeUpdates() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        for (action, title) in [(ExplorerContextMenu.Action.trash, "Move to Trash"), (.openInBrowser, "Open in Browser")] {
            let index = try #require(menu.items.firstIndex { $0.title == title })
            menu.performActionForItem(at: index)
            #expect(received?.0 == action)
            #expect(received?.1 == .local(url))
        }
        for (operation, title) in [(ExplorerStore.NameEdit.Operation.newFile, "New File"), (.newFolder, "New Folder"), (.rename, "Rename")] {
            let index = try #require(menu.items.firstIndex { $0.title == title })
            menu.performActionForItem(at: index)
            #expect(edited == operation)
        }
        let folder = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil, onShowDiff: { _ in })
        #expect(!folder.items.contains { $0.title == "Open in Browser" })
        let blocked = ExplorerContextMenu(location: .local(url), isDirectory: true, basePath: nil,
                                          allowsActions: false, onShowDiff: { _ in })
        #expect(blocked.items.count == 4)
        let container = try explorerTestModelContainer()
        let host = try HostStore(context: container.mainContext).addRemote(
            name: "server", basePath: "/repo", hostname: "unused", user: "test", identityFile: "")
        let remote = ExplorerContextMenu(location: .remote(hostID: host.persistentModelID, path: url.path),
                                         isDirectory: false, basePath: nil, onShowDiff: { _ in })
        #expect(remote.items.count == 4)
    }

    @Test func inlineNamesUseChildRowsAndPreserveFailedInput() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        let root = ExplorerItem(location: .local(directory), isDirectory: true)
        let rootMenu = ExplorerContextMenu(location: root.location, isDirectory: true, basePath: nil,
                                           createsOnly: true, onEdit: { coordinator.beginEditing($0, item: root) },
                                           onShowDiff: { _ in })
        #expect(rootMenu.items.map(\.title) == ["New File", "New Folder"])
        rootMenu.performActionForItem(at: 0)
        let rootEdit = try #require(store.nameEdit)
        #expect(rootEdit.target == root.location)
        #expect(rootEdit.parent == nil)
        #expect(outline.row(forItem: rootEdit.item) >= 0)
        coordinator.cancelEditing()
        for action in [ExplorerStore.NameEdit.Operation.newFile, .newFolder] {
            coordinator.beginEditing(action, item: parent)
            let edit = try #require(store.nameEdit)
            #expect(edit.target.path == folder.path)
            #expect(edit.parent === parent)
            #expect(outline.isItemExpanded(parent))
            #expect(outline.parent(forItem: edit.item) as? ExplorerItem === parent)
            #expect(edit.item.isDirectory == (action == .newFolder))
            #expect(!FileManager.default.fileExists(atPath: edit.item.location.path))
            store.updateName("partial")
            coordinator.beginEditing(.rename, item: edit.item)
            #expect(store.nameEdit?.item === edit.item)
            #expect(store.nameEdit?.operation == action)
            #expect(store.nameEdit?.name == "partial")
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
            #expect(edit.target == .local(folder.appendingPathComponent("existing.txt")))
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
}
