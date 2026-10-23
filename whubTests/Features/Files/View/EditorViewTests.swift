import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
import WhubGit
import WhubClient
@testable import whub

@Suite @MainActor
struct EditorViewTests {
    @Test func fileEditorRestoresFocusAndPositionAfterFeatureSwitch() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("focus.txt")
        try Data((0..<100).map { "line \($0) 日本語😀\n" }.joined().utf8).write(to: url)
        let files = FilesStore()
        let store = files.activeEditor
        let location = FileLocation.local(url)
        store.local.load(location)
        store.open(.file(location))
        let file = try #require(store.file(for: location))
        let window = EditorFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try #require(window.contentView)
        let coordinator = RetainedPageContainer<Int, AnyView>.Coordinator()
        let otherFile = FileStore(source: "AgentBook substitute")
        var selectedPage = 1
        let root: (Int, RetainedPageActivity) -> AnyView = { page, activity in
            let content = page == 1
                ? AnyView(EditorView().environmentObject(store).environmentObject(files).environmentObject(files.git))
                : AnyView(CodeEditorView(state: otherFile, editorID: "other", onEdit: {},
                                         source: otherFile.textStorage.string, language: nil, hunks: []))
            return AnyView(content.environment(\.isRetainedPageActive, page == selectedPage)
                .environment(\.retainedPageActivity, activity))
        }
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        try await waitForEditorTest {
            container.layoutSubtreeIfNeeded()
            return !file.editorViews.views.isEmpty
        }
        let editorID = try #require(file.editorViews.views.keys.first)
        let scroll = try #require(file.editorViews.views[editorID])
        let text = try #require(scroll.documentView as? CodeTextView)
        #expect(window.makeFirstResponder(text))
        text.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        let selection = (text.string as NSString).range(of: "line 25")
        text.setSelectedRange(selection)
        text.scrollRangeToVisible(selection)
        let origin = scroll.contentView.bounds.origin
        #expect(file.hasUnsavedChanges)

        selectedPage = 2
        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(window.firstResponder !== text)
        container.layoutSubtreeIfNeeded()
        let otherText = try #require(otherFile.editorViews.views["other"]?.documentView)
        #expect(window.makeFirstResponder(otherText))
        #expect(file.editorPositions[editorID]?.selectedRanges == [selection])
        #expect(file.editorPositions[editorID]?.scrollOrigin == origin)
        // Simulate AppKit losing native selection while the editor is hidden.
        text.setSelectedRange(NSRange(location: 0, length: 0))
        selectedPage = 1
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        try await waitForEditorTest { window.firstResponder === text }
        #expect(text.selectedRange() == selection)
        let restoredOrigin = scroll.contentView.bounds.origin
        #expect(abs(restoredOrigin.x - origin.x) < 1)
        #expect(abs(restoredOrigin.y - origin.y) < 1)
        #expect(text.string.hasPrefix("edited "))

        selectedPage = 2
        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        selectedPage = 1
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        selectedPage = 2
        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder !== text)
    }

    @Test func fileEditorFocusFollowsProjectSwitchAndPreservesPosition() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FilesStore()
        let locations = ["one.txt", "two.txt"].map { FileLocation.local(directory.appendingPathComponent($0)) }
        var stores: [EditorStore] = []
        for location in locations {
            try Data((0..<100).map { "line \($0) 日本語😀\n" }.joined().utf8).write(to: #require(location.localURL))
            files.explorer.selectedLocation = location
            files.activeEditor.local.load(location)
            files.activeEditor.open(.file(location))
            stores.append(files.activeEditor)
        }
        let window = EditorFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let activity = RetainedPageActivity()
        activity.setActive(true)
        func root() -> AnyView {
            AnyView(EditorView().environmentObject(files.activeEditor).environmentObject(files)
                .environmentObject(files.git).environment(\.retainedPageActivity, activity))
        }
        files.explorer.selectedLocation = locations[0]
        let host = NSHostingView(rootView: root())
        window.contentView = host
        let firstFile = try #require(stores[0].file(for: locations[0]))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return firstFile.editorViews.views.values.first?.documentView === window.firstResponder
                && window.firstResponder is CodeTextView
        }
        let scroll = try #require(firstFile.editorViews.views.values.first)
        let first = try #require(scroll.documentView as? CodeTextView)
        let remembered = (first.string as NSString).range(of: "line 10")
        first.setSelectedRange(remembered)
        first.savePosition()
        let selection = (first.string as NSString).range(of: "line 20")
        first.setSelectedRange(selection)
        first.scrollRangeToVisible(selection)
        let origin = scroll.contentView.bounds.origin

        files.explorer.selectedLocation = locations[1]
        let editorID = try #require(first.editorID)
        #expect(firstFile.editorPositions[editorID]?.selectedRanges == [selection])
        #expect(firstFile.editorPositions[editorID]?.scrollOrigin == origin)
        host.rootView = root()
        let secondFile = try #require(stores[1].file(for: locations[1]))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return secondFile.editorViews.views.values.first?.documentView === window.firstResponder
                && window.firstResponder is CodeTextView
        }
        first.setSelectedRange(NSRange(location: 0, length: 0))
        files.explorer.selectedLocation = locations[0]
        host.rootView = root()
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === first
        }
        #expect(first.selectedRange() == selection)
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
        #expect(stores[0].selectedTab == .file(locations[0]))

        files.explorer.selectedLocation = locations[1]
        host.rootView = root()
        host.layoutSubtreeIfNeeded()
        files.explorer.selectedLocation = locations[0]
        host.rootView = root()
        activity.setActive(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder !== secondFile.editorViews.views.values.first?.documentView)
    }

    @Test func editorPositionsAreSeparateAndClampAfterShorterContent() async throws {
        let first = FileStore(content: .text("日本語😀 first file"), isEditable: true)
        let second = FileStore(content: .text("second file"), isEditable: true)
        let firstHost = NSHostingView(rootView: CodeEditorView(state: first, editorID: "one", onEdit: {},
                                                             source: first.textStorage.string, language: nil, hunks: []))
        let secondHost = NSHostingView(rootView: CodeEditorView(state: first, editorID: "two", onEdit: {},
                                                              source: first.textStorage.string, language: nil, hunks: []))
        let otherHost = NSHostingView(rootView: CodeEditorView(state: second, editorID: "one", onEdit: {},
                                                             source: second.textStorage.string, language: nil, hunks: []))
        let window = EditorFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 300),
                                          styleMask: [.titled], backing: .buffered, defer: false)
        for (index, host) in [firstHost, secondHost, otherHost].enumerated() {
            host.frame = NSRect(x: index * 600, y: 0, width: 600, height: 300)
            window.contentView?.addSubview(host)
        }
        try await waitForEditorTest {
            [firstHost, secondHost, otherHost].forEach { $0.layoutSubtreeIfNeeded() }
            return first.editorViews.views.count == 2 && second.editorViews.views.count == 1
        }
        let one = try #require(first.editorViews.views["one"]?.documentView as? CodeTextView)
        let two = try #require(first.editorViews.views["two"]?.documentView as? CodeTextView)
        let other = try #require(second.editorViews.views["one"]?.documentView as? CodeTextView)
        #expect(window.makeFirstResponder(one))
        one.setSelectedRange(NSRange(location: 6, length: 4))
        #expect(window.makeFirstResponder(two))
        two.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(window.makeFirstResponder(other))
        other.setSelectedRange(NSRange(location: 1, length: 2))
        other.savePosition()
        #expect(first.editorPositions["one"]?.selectedRanges == [NSRange(location: 6, length: 4)])
        #expect(first.editorPositions["two"]?.selectedRanges == [NSRange(location: 3, length: 0)])
        #expect(second.editorPositions["one"]?.selectedRanges == [NSRange(location: 1, length: 2)])
        first.replace(source: "x")
        one.restorePosition()
        two.restorePosition()
        other.restorePosition()
        #expect(one.selectedRange() == NSRange(location: 1, length: 0))
        #expect(two.selectedRange() == NSRange(location: 1, length: 0))
        #expect(other.selectedRange() == NSRange(location: 1, length: 2))
        withExtendedLifetime([firstHost, secondHost, otherHost]) {}
    }

    @Test func findBarPreservesUnsavedText() async throws {
        let file = FileStore(content: .text("saved"), isEditable: true)
        let source = "日本語 target 😀 target unsaved"
        file.textStorage.replaceCharacters(in: NSRange(location: 0, length: file.textStorage.length), with: source)
        file.content = .text(source)
        let host = NSHostingView(rootView: CodeEditorView(state: file, editorID: "find", onEdit: {},
                                                         source: source, language: nil, hunks: []))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return file.editorViews.views["find"] != nil
        }
        let scroll = try #require(file.editorViews.views["find"])
        let text = try #require(scroll.documentView as? CodeTextView)
        #expect(text.usesFindBar && text.isIncrementalSearchingEnabled)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        text.performTextFinderAction(action)
        #expect(scroll.isFindBarVisible)
        action.tag = NSTextFinder.Action.hideFindInterface.rawValue
        text.performTextFinderAction(action)
        #expect(!scroll.isFindBarVisible)
        #expect(text.string == source)
        #expect(file.hasUnsavedChanges)
        #expect(file.savedSource == "saved")
        #expect(!file.undoManager.canUndo)
        withExtendedLifetime(host) {}
    }

    @Test func alignedDiffPreservesWholeFilesAndOriginalCopyText() {
        for (before, after) in [("", ""), ("", "added\n"), ("deleted\n", ""),
                                ("top\nold\nbottom\n", "top\nnew\nextra\nbottom\n"),
                                ("\u{FEFF}日本語😀\r\nlast", "\u{FEFF}日本語😀\r\nlast\r\n")] {
            let layout = DiffLayout(before: before, after: after)
            #expect(layout.before.count == layout.after.count)
            #expect(layout.before.map(\.source).joined() == before)
            #expect(layout.after.map(\.source).joined() == after)
            for (lines, original) in [(layout.before, before), (layout.after, after)] {
                let range = NSRange(location: 0, length: lines.map(\.displayText).joined().utf16.count)
                #expect(DiffLayout.copiedText(lines: lines, range: range) == original)
            }
        }
        let deleted = DiffLayout(before: "top\nremoved\nbottom\n", after: "top\nbottom\n")
        #expect(deleted.before.map(\.number) == [1, 2, 3])
        #expect(deleted.after.map(\.number) == [1, nil, 2])
        #expect(deleted.before[1].change == .deleted)
        #expect(deleted.after[1].change == nil)
        #expect(DiffLayout.copiedText(lines: deleted.after, range: NSRange(location: 4, length: 8)) == "bottom\n")
        let added = DiffLayout(before: "top\nbottom", after: "top\nadded\nbottom")
        #expect(added.before.map(\.number) == [1, nil, 2])
        #expect(added.after[1].change == .added)
        let changed = DiffLayout(before: "old\n", after: "new\n")
        #expect(changed.before[0].change == .modified)
        #expect(changed.after[0].change == .modified)
    }

    @Test func diffRendererIsReadOnlyAlignedAndScrollsTogether() async throws {
        let before = (0..<100).map { "line\($0)\n" }.joined()
        let after = "inserted\n" + before
        let host = NSHostingView(rootView: DiffView(before: before, after: after,
                                                  fileURL: URL(fileURLWithPath: "/file.swift")))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        func editors(in view: NSView) -> [CodeTextView] {
            if let editor = view as? CodeTextView { return [editor] }
            return view.subviews.flatMap { editors(in: $0) }
        }
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return editors(in: host).count == 2
        }
        let panes = editors(in: host)
        #expect(panes.allSatisfy { !$0.isEditable && $0.isSelectable })
        #expect(panes.allSatisfy { !$0.validateMenuItem(NSMenuItem(title: "Save", action: #selector(CodeTextView.saveDocument(_:)), keyEquivalent: "s")) })
        let left = try #require(panes.first { $0.diffLines?.first?.number == nil })
        let right = try #require(panes.first { $0.diffLines?.first?.change == .added })
        func y(of text: CodeTextView) throws -> CGFloat {
            let manager = try #require(text.layoutManager)
            let container = try #require(text.textContainer)
            manager.ensureLayout(for: container)
            let index = (text.string as NSString).range(of: "line20").location
            let glyph = manager.glyphIndexForCharacter(at: index)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        }
        #expect(try y(of: left) == y(of: right))
        let leftScroll = try #require(left.enclosingScrollView)
        let rightScroll = try #require(right.enclosingScrollView)
        leftScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: leftScroll.contentView)
        #expect(rightScroll.contentView.bounds.minY == leftScroll.contentView.bounds.minY)
        rightScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: rightScroll.contentView)
        #expect(rightScroll.contentView.bounds.minY == leftScroll.contentView.bounds.minY)
        withExtendedLifetime(host) {}
    }

    @Test func localSaveCommandPreservesEncodingAndWatcherUpdatesDocument() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file.txt")
        let bom = Data([0xef, 0xbb, 0xbf])
        try (bom + Data("first\r\n".utf8)).write(to: url)
        let files = FilesStore()
        let editor = files.activeEditor
        let connections = RemoteConnectionStore()
        let location = FileLocation.local(url)
        files.open(location, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        let local = try #require(editor.local.fileStores[location])
        let document = local.document
        #expect(editor.file(for: location) === document)
        document.content = .text("second\n")
        let text = CodeTextView()
        text.fileStore = document
        #expect(text.validateMenuItem(NSMenuItem(title: "Save", action: #selector(CodeTextView.saveDocument(_:)), keyEquivalent: "s")))
        text.saveDocument(nil)
        #expect(try Data(contentsOf: url) == bom + Data("second\r\n".utf8))
        #expect(!document.hasUnsavedChanges)
        try Data("updated externally".utf8).write(to: url)
        try await waitForEditorTest { document.textStorage.string == "updated externally" }
        #expect(local.diskMessage == nil)
        editor.close(.file(location))
        #expect(editor.local.fileStores.isEmpty)
        #expect(editor.file(for: location) == nil)
    }
}

// Keep focus tests independent of the user's foreground application.
@MainActor private final class EditorFocusTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
