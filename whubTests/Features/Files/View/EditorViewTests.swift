// テスト一覧:
// - workspaceEditorFollowsFileSelectionAfterProjectSwitch(): Workspaceの分割表示が切替後のEditorを表示する。
// - tabShortcutsPreserveEditorStateAndCloseSelectedTabs(): [TAB-F-001] [TAB-F-002] [TAB-F-006] [TAB-F-007] [TAB-F-008]
// - fileEditorRestoresFocusAndPositionAfterFeatureSwitch(): Feature切替後の入力フォーカス・選択・スクロール位置を復元する。
// - fileEditorFocusFollowsProjectSwitchAndPreservesPosition(): Project切替後の入力フォーカスと位置を復元する。
// - editorPositionsAreSeparateAndClampAfterShorterContent(): 文書・Editor別の位置保持と短縮時の範囲補正。
// - findBarPreservesUnsavedText(): 検索バーの開閉で未保存本文を保持する。
// - editorClipsTextOutsideRulerAfterScrollingAndResizing(): 本文領域と行番号を分離し、幅と桁数の変化に追従する。
// - alignedDiffPreservesWholeFilesAndOriginalCopyText(): 差分の行揃えと元のコピー文字列を保持する。
// - diffRendererIsReadOnlyAlignedAndScrollsTogether(): 差分表示の読取専用・行揃え・スクロール同期。
// - localSaveCommandPreservesEncodingAndWatcherUpdatesDocument(): 保存コマンドの文字コード保持と外部更新の反映。

import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
import WhubGit
import WhubClient
@testable import WhubAgent
@testable import whub

@Suite @MainActor
struct EditorViewTests {
    @Test func workspaceEditorFollowsFileSelectionAfterProjectSwitch() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FilesStore()
        let connections = RemoteConnectionStore()
        let servers = RemoteServerStore(connections: connections)
        let database = try explorerTestModelContainer()
        let book = AgentBookStore(context: database.mainContext,
                                 runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { book.disconnect() }
        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")
        try Data("first file".utf8).write(to: firstURL)
        try Data("second file".utf8).write(to: secondURL)
        files.preview(.local(firstURL), hosts: [], connections: connections, servers: servers)
        let first = try #require(files.activeEditor.file(for: .local(firstURL)))
        let host = NSHostingView(rootView: WorkspaceEditorTestRoot(files: files)
            .environmentObject(book).environmentObject(connections).environmentObject(servers)
            .modelContainer(database))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); withExtendedLifetime(database) {} }
        window.contentView = host
        try? await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return !first.editorViews.views.isEmpty
        }
        try #require(!first.editorViews.views.isEmpty, "Initial file editor is displayed")
        files.explorer.selectedLocation = .local(directory)
        files.preview(.local(secondURL), hosts: [], connections: connections, servers: servers)
        #expect(files.activeEditor.selectedTab == .file(.local(secondURL)))
        let second = try #require(files.activeEditor.file(for: .local(secondURL)))
        try? await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return second.editorViews.views.values.contains { $0.documentView is CodeTextView }
        }
        #expect(!second.editorViews.views.isEmpty, "File editor follows project selection")
        withExtendedLifetime(host) {}
    }

    @Test func tabShortcutsPreserveEditorStateAndCloseSelectedTabs() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTabTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FilesStore()
        let store = files.activeEditor
        let locations = try (1...9).map { index in
            let url = directory.appendingPathComponent("file\(index).md")
            try Data("# File \(index)".utf8).write(to: url)
            let location = FileLocation.local(url)
            store.local.load(location)
            store.open(.file(location))
            return location
        }
        let documents = try locations.map { try #require(store.file(for: $0)) }
        let host = NSHostingView(rootView: EditorView().environmentObject(store)
            .environmentObject(files).environmentObject(files.git))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is CodeTextView
        }
        var editors: [CodeTextView] = []

        for (index, keyCode) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            try sendTabTestKey(String(index + 1), code: UInt16(keyCode), to: window)
            try await waitForEditorTest {
                host.layoutSubtreeIfNeeded()
                return store.selectedTab == .file(locations[index])
                    && documents[index].editorViews.views.values.contains { $0.documentView === window.firstResponder }
            }
            let editor = try #require(window.firstResponder as? CodeTextView)
            editors.append(editor)
            #expect(store.file(for: locations[index]) === documents[index])
            if index == 0 {
                editor.setSelectedRange(NSRange(location: 3, length: 0))
                editor.insertText("X", replacementRange: editor.selectedRange())
            }
        }
        try sendTabTestKey("1", code: 18, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === editors[0]
        }
        #expect(editors[0].string == "# FXile 1")
        #expect(editors[0].selectedRange() == NSRange(location: 4, length: 0))
        #expect(documents[0].hasUnsavedChanges)
        editors[0].insertText("Y", replacementRange: editors[0].selectedRange())
        #expect(editors[0].string == "# FXYile 1")
        try sendTabTestKey("9", code: 25, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === editors[8]
        }
        try sendTabTestKey("w", code: 13, to: window)
        #expect(store.tabs.count == 8)
        #expect(store.tabs.contains(try #require(store.selectedTab)))
        #expect(store.file(for: locations[8]) == nil)
        #expect(store.file(for: locations[0]) === documents[0])
        #expect(documents[0].textStorage.string == "# FXYile 1")
        for location in locations.dropFirst().dropLast() { store.close(.file(location)) }
        try #require(store.local.fileStores[locations[0]]).save()
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === editors[0]
        }
        try sendTabTestKey("w", code: 13, to: window)
        #expect(store.tabs.isEmpty && store.selectedTab == nil)
    }

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

    @Test func editorClipsTextOutsideRulerAfterScrollingAndResizing() async throws {
        let line = String(repeating: "content ", count: 30) + "\n"
        let file = FileStore(source: String(repeating: line, count: 100))
        let host = NSHostingView(rootView: CodeEditorView(state: file, editorID: "clip", onEdit: {},
                                                         source: file.textStorage.string, language: nil, hunks: []))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return file.editorViews.views["clip"] != nil
        }
        let scroll = try #require(file.editorViews.views["clip"])
        let ruler = try #require(scroll.verticalRulerView)
        func checkRegions() {
            let rulerFrame = scroll.convert(ruler.bounds, from: ruler)
            #expect(scroll.contentView.frame.minX >= rulerFrame.maxX)
            #expect(scroll.contentView.clipsToBounds)
            #expect(scroll.contentView.contentInsets.left == 0)
        }
        checkRegions()
        #expect(scroll.contentView.bounds.minX == 0)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 100))
        scroll.tile()
        checkRegions()
        #expect(scroll.contentView.bounds.minX == 100)
        host.frame.size.width = 800
        host.layoutSubtreeIfNeeded()
        checkRegions()
        #expect(scroll.contentView.bounds.minX == 100)
        let oldThickness = ruler.ruleThickness
        file.updateReadOnly(source: String(repeating: line, count: 1000))
        host.rootView = CodeEditorView(state: file, editorID: "clip", onEdit: {},
                                      source: file.textStorage.string, language: nil, hunks: [])
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return ruler.ruleThickness > oldThickness
        }
        checkRegions()
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
        let before = (0..<100).map { "line\($0) " + String(repeating: "content ", count: 30) + "\n" }.joined()
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
        for scroll in [leftScroll, rightScroll] {
            let ruler = try #require(scroll.verticalRulerView)
            #expect(scroll.contentView.frame.minX >= scroll.convert(ruler.bounds, from: ruler).maxX)
        }
        leftScroll.contentView.scroll(to: NSPoint(x: 100, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: leftScroll.contentView)
        #expect(leftScroll.contentView.bounds.minX > 0)
        #expect(rightScroll.contentView.bounds.origin == leftScroll.contentView.bounds.origin)
        rightScroll.contentView.scroll(to: NSPoint(x: 200, y: 200))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: rightScroll.contentView)
        #expect(rightScroll.contentView.bounds.origin == leftScroll.contentView.bounds.origin)
        withExtendedLifetime(host) {}
    }

    @Test func diffScrollSyncClampsToEachDocumentWithoutMovingSource() {
        let left = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let right = NSScrollView(frame: left.frame)
        left.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1000))
        right.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 1000))
        let sync = DiffScrollSync()
        sync.attach(left, before: true)
        sync.attach(right, before: false)
        left.contentView.scroll(to: NSPoint(x: 900, y: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: left.contentView)
        #expect(left.contentView.bounds.minX == 900)
        #expect(right.contentView.bounds.maxX == 500)
        #expect(right.contentView.bounds.minY == 100)
        right.contentView.scroll(to: NSPoint(x: 40, y: 200))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: right.contentView)
        #expect(left.contentView.bounds.origin == NSPoint(x: 40, y: 200))
        sync.disconnect()
        left.contentView.scroll(to: NSPoint(x: 200, y: 300))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: left.contentView)
        #expect(right.contentView.bounds.origin == NSPoint(x: 40, y: 200))
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

private struct WorkspaceEditorTestRoot: View {
    @ObservedObject var files: FilesStore
    private let leftFocus = TabPaneFocus()
    private let agentFocus = TabPaneFocus()
    private let inputFocus = AgentBookFocus()

    var body: some View {
        RetainedPageContainer(selection: true) { _ in
            WorkspacePanes(section: .editor, leftFocus: leftFocus, agentFocus: agentFocus,
                           agentInputFocus: inputFocus, openLink: { _, _ in false })
                .environmentObject(files.activeEditor)
        }
        .environmentObject(files)
        .environmentObject(files.git)
    }
}
