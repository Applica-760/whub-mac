// 検証内容: 本文の遅延取得・再利用、ホスト識別、ルート検証、失敗表示、閉じたタブへの遅延応答破棄。
// リモート保存・競合拒否・応答消失・保存中の追加入力と、ローカルの保存・タブ操作も確認する。
// リロード・切断・再接続・取得失敗時の旧本文保持と、旧セッションの応答破棄も確認する。
// 限界: 通信と接続識別は制御した値を使用。実SSH・画面操作は別途確認する。
import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
import WhubClient
@testable import whub

@Suite @MainActor
struct EditorStoreTests {
    @Test func fileEditorRestoresFocusAndPositionAfterFeatureSwitch() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
        try await eventually {
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
        try await eventually { window.firstResponder === text }
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
        try await eventually {
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

    @Test(arguments: ["\n", "\r\n", "\r", "\r\nwith mixed\n"], [false, true])
    func fileEncodingPreservesLineEndingsAndBOM(ending: String, bom: Bool) {
        let prefix = bom ? "\u{FEFF}" : ""
        let original = prefix + "before" + ending
        let source = "日本語\nnext\n"
        let expected = prefix + (ending.contains("mixed") ? source : "日本語" + ending + "next" + ending)
        let savedData = FileEncoding.encode(source, preserving: Data(original.utf8))
        let savedText = FileEncoding.encode(source, preserving: original)
        #expect(savedData == Data(expected.utf8))
        #expect(savedData == Data(savedText.utf8))
        #expect(FileEncoding.decode(savedData) == (bom ? String(expected.dropFirst()) : expected))
        if bom {
            #expect(FileEncoding.encode(prefix + source, preserving: original).utf8.elementsEqual(savedText.utf8))
        }
    }

    @Test func fileEncodingAcceptsEmptyUTF8AndRejectsInvalidBytes() {
        #expect(FileEncoding.decode(Data()) == "")
        #expect(FileEncoding.decode(Data([0xff])) == nil)
        #expect(FileEncoding.decode(Data([0xff, 0xfe, 0x61, 0x00])) == nil)
        #expect(FileEncoding.encode("", preserving: Data("\u{FEFF}before".utf8)) == Data([0xef, 0xbb, 0xbf]))
    }

    @Test func findBarPreservesUnsavedText() async throws {
        let file = FileStore(content: .text("saved"), isEditable: true)
        let source = "日本語 target 😀 target unsaved"
        file.textStorage.replaceCharacters(in: NSRange(location: 0, length: file.textStorage.length), with: source)
        file.content = .text(source)
        let host = NSHostingView(rootView: CodeEditorView(state: file, editorID: "find", onEdit: {},
                                                         source: source, language: nil, hunks: []))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        try await eventually {
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
        try await eventually {
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

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func edit(_ file: FileStore, _ source: String) {
        file.textStorage.replaceCharacters(in: NSRange(location: 0, length: file.textStorage.length), with: source)
        file.content = .text(source)
    }

    @Test func remoteSaveKeepsNewerEditsAndPreventsDuplicateSaves() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let editor = EditorStore()
        let location = root.appending("file")
        let gate = ViewerGate()
        var disk = "original"
        var writes = 0
        editor.remote.load(location, root: root, write: { rootPath, path, expected, text in
            #expect(rootPath == "/project" && path == "file")
            #expect(expected == disk)
            writes += 1
            await gate.wait()
            disk = text
            return text
        }) { _, _, _ in disk }
        try await eventually { editor.remote.file(for: location) != nil }
        let remote = try #require(editor.remote.fileStores[location])
        let file = try #require(remote.document)
        #expect(file.isEditable && file.saveAction != nil && file.canSave?() == true)
        edit(file, "submitted")
        let saving = Task { await remote.save() }
        try await eventually { gate.waiting }
        #expect(remote.isSaving && !remote.canSave)
        #expect(await remote.save() == false)
        #expect(await remote.confirmClose(choice: .discard) == false)
        edit(file, "newer edit")
        editor.refresh()
        gate.release()
        #expect(await saving.value)
        #expect(disk == "submitted" && writes == 1)
        #expect(file.savedSource == "submitted")
        #expect(file.textStorage.string == "newer edit" && file.hasUnsavedChanges)
        #expect(await remote.confirmClose(choice: .cancel) == false)
        #expect(await remote.confirmClose(choice: .discard))
    }

    @Test func remoteConflictAndFailedClosePreserveDraft() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        var disk = "original"
        let store = RemoteEditorStore()
        store.load(location, root: root, write: { _, _, expected, text in
            guard expected.utf8.elementsEqual(disk.utf8) else {
                throw WhubClientError.api(status: 409, code: "conflict", message: "外部変更")
            }
            disk = text
            return text
        }) { _, _, _ in disk }
        try await eventually { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "draft")
        disk = "external"
        #expect(await remote.confirmClose(choice: .save) == false)
        #expect(disk == "external" && file.savedSource == "original")
        #expect(file.hasUnsavedChanges && remote.message != nil)
        remote.refresh()
        try await eventually { if case .loaded = remote.state { return true }; return false }
        #expect(file.textStorage.string == "draft" && file.hasUnsavedChanges)
        #expect(remote.message != nil)
    }

    @Test(arguments: [true, false])
    func remoteLostSaveResponseIsReconciledBeforeRetry(committed: Bool) async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        var disk = "original"
        var writes = 0
        let store = RemoteEditorStore()
        store.load(location, root: root, write: { _, _, _, text in
            writes += 1
            if committed { disk = text }
            throw SSHError.disconnected
        }) { _, _, _ in disk }
        try await eventually { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "submitted")
        #expect(await remote.save() == false)
        #expect(!remote.canSave && file.hasUnsavedChanges)
        #expect(await remote.save() == false)
        #expect(writes == 1)
        edit(file, "newer edit")
        remote.refresh()
        try await eventually { if case .loaded = remote.state { return remote.canSave }; return false }
        #expect(file.textStorage.string == "newer edit" && file.hasUnsavedChanges)
        #expect(file.savedSource == (committed ? "submitted" : "original"))
        #expect(writes == 1)
    }

    @Test(arguments: ["original", "submitted", "external"])
    func remoteUndoAfterUnconfirmedSaveStillProtectsTab(latest: String) async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        let other = root.appending("other")
        var reads = 0
        let editor = EditorStore()
        editor.remote.load(location, root: root, write: { _, _, _, _ in throw SSHError.disconnected }) { _, _, _ in
            reads += 1
            return reads == 1 ? "original" : latest
        }
        editor.remote.load(other, root: root, write: { _, _, _, text in text }) { _, _, _ in "other" }
        editor.preview(.file(location))
        try await eventually { editor.remote.file(for: location) != nil }
        let remote = try #require(editor.remote.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "submitted")
        #expect(await remote.save() == false)
        edit(file, "original")
        #expect(remote.needsCloseConfirmation)
        #expect(await remote.confirmClose(choice: .cancel) == false)
        editor.preview(.file(other))
        #expect(editor.tabs == [.file(location), .file(other)])
        remote.refresh()
        try await eventually { if case .loaded = remote.state { return true }; return false }
        #expect(file.textStorage.string == "original")
        #expect(remote.needsCloseConfirmation == (latest != "original"))
        if latest == "external" { #expect(!remote.canSave && remote.message != nil) }
    }

    @Test func remoteDirtyPreviewAndReconnectKeepDraft() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        let other = root.appending("other")
        let first = NSObject()
        let second = NSObject()
        var connection: ObjectIdentifier? = ObjectIdentifier(first)
        let disk = NSMutableString(string: "original")
        let editor = EditorStore()
        editor.remote.load(location, root: root, connection: { connection }, write: { _, _, _, text in text }) { _, _, _ in disk as String }
        editor.remote.load(other, root: root, write: { _, _, _, text in text }) { _, _, _ in "other" }
        editor.preview(.file(location))
        try await eventually { editor.remote.file(for: location) != nil }
        let remote = try #require(editor.remote.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "draft")
        editor.preview(.file(other))
        #expect(editor.tabs == [.file(location), .file(other)])
        #expect(editor.previewTab == .file(other))
        connection = nil
        editor.remote.synchronizeConnections()
        #expect(!remote.canSave && file.textStorage.string == "draft")
        disk.setString("external")
        connection = ObjectIdentifier(second)
        editor.remote.synchronizeConnections()
        try await eventually { if case .loaded = remote.state { return true }; return false }
        #expect(file.textStorage.string == "draft" && file.savedSource == "original")
        #expect(remote.message != nil)
    }

    @Test func remoteTracksByteChangesInCanonicallyEquivalentText() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        var disk = "é"
        let store = RemoteEditorStore()
        store.load(location, root: root, write: { _, _, _, text in
            disk = text
            return text
        }) { _, _, _ in disk }
        try await eventually { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "e\u{301}")
        #expect(remote.hasUnsavedChanges && remote.needsCloseConfirmation)
        #expect(await remote.save())
        #expect(disk.utf8.elementsEqual("e\u{301}".utf8))
        #expect(!remote.hasUnsavedChanges)
    }

    @Test func remoteSavePreservesBOMLineEndingsAndCloseWaitsForSuccess() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("file")
        var disk = "\u{FEFF}original\r\n"
        let store = RemoteEditorStore()
        store.load(location, root: root, write: { _, _, expected, text in
            #expect(expected.utf8.elementsEqual(disk.utf8))
            disk = text
            return text
        }) { _, _, _ in disk }
        try await eventually { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "日本語\nnext\n")
        #expect(await remote.confirmClose(choice: .save))
        #expect(disk.utf8.elementsEqual("\u{FEFF}日本語\r\nnext\r\n".utf8))
        #expect(!file.hasUnsavedChanges)
        remote.refresh()
        try await eventually { remote.canSave }
        #expect(!file.hasUnsavedChanges)
    }

    @Test func remoteReadsAndEdits() async throws {
        let fixture = try ViewerFixture()
        let editor = EditorStore()
        let root = fixture.root()
        let location = root.appending("src/a.swift")
        var requests = 0
        editor.remote.load(location, root: root, write: { _, _, _, text in text }) { _, rootPath, path in
            #expect(rootPath == "/project")
            #expect(path == "src/a.swift")
            requests += 1
            return "let 日本語 = 1\n"
        }
        editor.preview(.file(location))
        editor.remote.load(location, root: root, write: { _, _, _, text in text }) { _, _, _ in
            Issue.record("重複取得")
            return "wrong"
        }
        try await eventually { editor.remote.file(for: location) != nil }
        let file = try #require(editor.remote.file(for: location))
        #expect(file.textStorage.string == "let 日本語 = 1\n")
        #expect(requests == 1)
        #expect(file.isEditable)
        #expect(!file.hasUnsavedChanges)
        #expect(file.saveAction != nil)
        #expect(file.canSave?() == true)
        let content = CodeEditorView(state: file, editorID: "remote", onEdit: {}, source: file.textStorage.string,
                                      language: "swift", hunks: [])
        let renderer = NSHostingView(rootView: content)
        renderer.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        renderer.layoutSubtreeIfNeeded()
        try await eventually { file.editorViews.views["remote"] != nil }
        let text = try #require(file.editorViews.views["remote"]?.documentView as? CodeTextView)
        #expect(text.isEditable)
        #expect(text.isSelectable)
        #expect(text.validateMenuItem(NSMenuItem(title: "Save", action: #selector(CodeTextView.saveDocument(_:)), keyEquivalent: "s")))
        editor.open(.file(location))
        #expect(editor.previewTab == nil)
        let otherRoot = fixture.root(second: true)
        let other = otherRoot.appending("src/a.swift")
        editor.remote.load(other, root: otherRoot, write: { _, _, _, text in text }) { _, _, _ in "other" }
        editor.open(.file(other))
        try await eventually { editor.remote.file(for: other) != nil }
        #expect(editor.tabs == [.file(location), .file(other)])
        #expect(editor.remote.file(for: other)?.textStorage.string == "other")
        editor.move(.file(other), before: .file(location))
        #expect(editor.tabs == [.file(other), .file(location)])
        editor.close(.file(location))
        editor.close(.file(other))
        #expect(editor.remote.states.isEmpty)
    }

    @Test(arguments: [true, false])
    func lateResultAfterPreviewReplacement(succeeds: Bool) async throws {
        let fixture = try ViewerFixture()
        let editor = EditorStore()
        let root = fixture.root()
        let old = root.appending("old")
        let next = root.appending("next")
        let gate = ViewerGate()
        var returned = false
        editor.remote.load(old, root: root, write: { _, _, _, text in text }) { _, _, _ in
            await gate.wait()
            returned = true
            if succeeds { return "old" }
            throw SSHError.disconnected
        }
        editor.preview(.file(old))
        try await eventually { gate.waiting }
        editor.remote.load(next, root: root, write: { _, _, _, text in text }) { _, _, _ in "next" }
        editor.preview(.file(next))
        #expect(editor.remote.states[old] == nil)
        editor.remote.load(old, root: root, write: { _, _, _, text in text }) { _, _, _ in "new" }
        editor.open(.file(old))
        try await eventually { editor.remote.file(for: old) != nil }
        gate.release()
        try await eventually { returned }
        #expect(editor.remote.file(for: old)?.textStorage.string == "new")
        #expect(editor.selectedTab == .file(old))
        editor.close(.file(old))
        editor.close(.file(next))
    }

    @Test func failureAndInvalidRoot() async throws {
        let fixture = try ViewerFixture()
        let store = RemoteEditorStore()
        let root = fixture.root()
        let file = root.appending("missing")
        store.load(file, root: root, write: { _, _, _, text in text }) { _, _, _ in throw SSHError.disconnected }
        try await eventually { if case .failed = store.states[file] { return true }; return false }
        for location in [root.appending("../outside"), fixture.root(second: true).appending("file")] {
            store.load(location, root: root, write: { _, _, _, text in text }) { _, _, _ in
                Issue.record("不正なルートで取得が実行された")
                return "wrong"
            }
            guard case .failed = store.states[location] else { Issue.record("エラーが必要"); return }
        }
        store.close(file)
        store.load(file, root: root, write: { _, _, _, text in text }) { _, _, _ in "" }
        try await eventually { store.file(for: file) != nil }
        #expect(store.file(for: file)?.textStorage.string == "")
    }

    @Test func refreshAndFailureRetainEditableFile() async throws {
        let fixture = try ViewerFixture()
        let editor = EditorStore()
        let root = fixture.root()
        let location = root.appending("file")
        var reads = 0
        editor.remote.load(location, root: root, write: { _, _, _, text in text }) { _, rootPath, path in
            #expect(rootPath == "/project")
            #expect(path == "file")
            reads += 1
            switch reads {
            case 1: return "first"
            case 2: return "second"
            case 3: throw SSHError.operationFailed("ファイルが削除されました")
            default: return ""
            }
        }
        editor.open(.file(location))
        try await eventually { editor.remote.file(for: location) != nil }
        let file = try #require(editor.remote.file(for: location))
        editor.refresh()
        try await eventually { file.textStorage.string == "second" }
        #expect(editor.remote.file(for: location) === file)
        #expect(editor.selectedTab == .file(location))
        #expect(file.isEditable)
        editor.refresh()
        try await eventually { if case .failed = editor.remote.states[location] { return true }; return false }
        #expect(file.textStorage.string == "second")
        #expect(editor.remote.file(for: location) === file)
        editor.refresh()
        try await eventually { file.textStorage.string.isEmpty }
        #expect(reads == 4)
        editor.close(.file(location))
        editor.refresh()
        #expect(editor.remote.states.isEmpty)
        #expect(reads == 4)
    }

    @Test(arguments: [true, false])
    func reconnectDiscardsOldSessionResult(succeeds: Bool) async throws {
        let fixture = try ViewerFixture()
        let store = RemoteEditorStore()
        let root = fixture.root()
        let location = root.appending("file")
        let firstSession = NSObject()
        let secondSession = NSObject()
        var session: ObjectIdentifier? = ObjectIdentifier(firstSession)
        let gate = ViewerGate()
        var reads = 0
        var returned = false
        store.load(location, root: root, connection: { session }, write: { _, _, _, text in text }) { _, _, _ in
            reads += 1
            if reads == 1 { return "cached" }
            if reads == 2 {
                await gate.wait()
                returned = true
                if succeeds { return "old session" }
                throw SSHError.disconnected
            }
            return "new session"
        }
        try await eventually { store.file(for: location) != nil }
        let file = try #require(store.file(for: location))
        store.refresh()
        try await eventually { gate.waiting }
        session = nil
        store.synchronizeConnections()
        guard case .disconnected = store.states[location] else { Issue.record("切断状態が必要"); return }
        #expect(file.textStorage.string == "cached")
        store.refresh()
        #expect(reads == 2)
        session = ObjectIdentifier(secondSession)
        store.synchronizeConnections()
        try await eventually { file.textStorage.string == "new session" }
        gate.release()
        try await eventually { returned }
        #expect(file.textStorage.string == "new session")
        #expect(store.file(for: location) === file)
        store.synchronizeConnections()
        #expect(reads == 3)
        store.close(location)
    }

    @Test func refreshAndCloseDiscardPendingResult() async throws {
        let fixture = try ViewerFixture()
        let store = RemoteEditorStore()
        let root = fixture.root()
        let location = root.appending("file")
        let gate = ViewerGate()
        var reads = 0
        var returned = false
        store.load(location, root: root, write: { _, _, _, text in text }) { _, _, _ in
            reads += 1
            if reads == 1 {
                await gate.wait()
                returned = true
                return "old"
            }
            return "latest"
        }
        try await eventually { gate.waiting }
        store.refresh()
        try await eventually { store.file(for: location)?.textStorage.string == "latest" }
        store.close(location)
        gate.release()
        try await eventually { returned }
        #expect(store.states[location] == nil)
        #expect(store.file(for: location) == nil)
        store.refresh()
        #expect(reads == 2)
    }

    @Test func localConflictPreservesEditsAndAdoptsLatest() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file.txt")
        try Data("original".utf8).write(to: url)
        let local = LocalFileStore(fileURL: url)
        let document = local.document
        document.content = .text("my edits")
        try Data("external".utf8).write(to: url)
        local.checkForExternalChanges()
        #expect(local.diskMessage != nil)
        #expect(document.hasUnsavedChanges)
        #expect(throws: LocalFileStore.SaveError.self) { try local.save() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external")
        #expect(document.savedSource == "original")
        try local.adoptLatest()
        #expect(document.textStorage.string == "external")
        #expect(!document.hasUnsavedChanges)
        #expect(local.diskMessage == nil)
        let revision = local.diskRevision
        try Data([0xff, 0xfe]).write(to: url)
        #expect(throws: LocalFileStore.SaveError.self) { try local.adoptLatest() }
        #expect(document.textStorage.string == "external")
        #expect(local.diskRevision == revision)
    }

    @Test func localSaveCommandPreservesEncodingAndWatcherUpdatesDocument() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
        try await eventually { document.textStorage.string == "updated externally" }
        #expect(local.diskMessage == nil)
        editor.close(.file(location))
        #expect(editor.local.fileStores.isEmpty)
        #expect(editor.file(for: location) == nil)
    }

    @Test func workspaceSwitchPreservesLocalTabsAndUnsavedContents() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let roots = ["projects/app", "worktrees/app-1", "projects/other"].map {
            directory.appendingPathComponent($0)
        }
        for root in roots {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["first.txt", "second.txt"] {
                try Data(root.path.utf8).write(to: root.appendingPathComponent(name))
            }
        }
        let files = FilesStore()
        let connections = RemoteConnectionStore()
        let selection = ExplorerPulldownSelection(
            locations: roots.map(FileLocation.local),
            selection: Binding(get: { files.explorer.selectedLocation }, set: { files.explorer.selectedLocation = $0 })
        )
        files.explorer.selectedLocation = .local(roots[0])
        let projectEditor = files.activeEditor
        let first = FileLocation.local(roots[0].appendingPathComponent("first.txt"))
        let second = FileLocation.local(roots[0].appendingPathComponent("second.txt"))
        files.open(first, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        files.preview(second, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        projectEditor.move(.file(second), before: .file(first))
        projectEditor.select(.file(first))
        let document = try #require(projectEditor.local.fileStores[first])
        document.document.content = .text("unsaved project edit")

        selection.move(by: 1)
        let worktreeEditor = files.activeEditor
        #expect(worktreeEditor !== projectEditor)
        #expect(worktreeEditor.tabs.isEmpty)
        let worktreeFile = FileLocation.local(roots[1].appendingPathComponent("first.txt"))
        files.preview(worktreeFile, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        let worktreeDocument = try #require(worktreeEditor.local.fileStores[worktreeFile])
        #expect(worktreeDocument.document.savedSource == roots[1].path)
        worktreeDocument.document.content = .text("unsaved worktree edit")

        selection.move(by: 1)
        #expect(files.activeEditor.tabs.isEmpty)
        files.explorer.selectedLocation = .local(roots[0])
        #expect(files.activeEditor === projectEditor)
        #expect(projectEditor.tabs == [.file(second), .file(first)])
        #expect(projectEditor.selectedTab == .file(first))
        #expect(projectEditor.previewTab == nil)
        #expect(document.document.hasUnsavedChanges)
        try document.save()
        #expect(try String(contentsOf: roots[0].appendingPathComponent("first.txt"), encoding: .utf8) == "unsaved project edit")
        #expect(try String(contentsOf: roots[1].appendingPathComponent("first.txt"), encoding: .utf8) == roots[1].path)
        projectEditor.close(.file(second))

        selection.move(by: 1)
        #expect(files.activeEditor === worktreeEditor)
        #expect(worktreeEditor.tabs == [.file(worktreeFile)])
        #expect(worktreeEditor.selectedTab == .file(worktreeFile))
        #expect(worktreeEditor.previewTab == .file(worktreeFile))
        #expect(worktreeDocument.document.hasUnsavedChanges)
        try worktreeDocument.save()
        #expect(try String(contentsOf: roots[1].appendingPathComponent("first.txt"), encoding: .utf8) == "unsaved worktree edit")
        worktreeEditor.close(.file(worktreeFile))
        projectEditor.close(.file(first))
    }

    @Test func remoteWorkspacesKeepSeparateTabsAndPendingReads() async throws {
        let fixture = try ViewerFixture()
        let roots = [fixture.root(), fixture.root().appending("worktree"), fixture.root(second: true)]
        let files = FilesStore()
        let gate = ViewerGate()
        files.explorer.selectedLocation = roots[0]
        let firstEditor = files.activeEditor
        let firstFile = roots[0].appending("file.swift")
        firstEditor.remote.load(firstFile, root: roots[0], write: { _, _, _, text in text }) { _, _, _ in
            await gate.wait()
            return "first host project"
        }
        firstEditor.preview(.file(firstFile))
        try await eventually { gate.waiting }
        for root in roots.dropFirst() {
            files.explorer.selectedLocation = root
            #expect(files.activeEditor !== firstEditor)
            #expect(files.activeEditor.tabs.isEmpty)
            let location = root.appending("file.swift")
            files.activeEditor.remote.load(location, root: root, write: { _, _, _, text in text }) { _, _, _ in "other workspace" }
            files.activeEditor.open(.file(location))
        }
        let lastEditor = files.activeEditor
        gate.release()
        try await eventually { firstEditor.file(for: firstFile) != nil }
        #expect(files.activeEditor === lastEditor)
        #expect(lastEditor.selectedTab == .file(roots[2].appending("file.swift")))
        for root in roots {
            files.explorer.selectedLocation = root
            let location = root.appending("file.swift")
            #expect(files.activeEditor.tabs == [.file(location)])
            #expect(files.activeEditor.selectedTab == .file(location))
            if root == roots[0] {
                #expect(files.activeEditor === firstEditor)
                #expect(firstEditor.previewTab == .file(firstFile))
                #expect(firstEditor.file(for: firstFile)?.savedSource == "first host project")
            }
            files.activeEditor.close(.file(location))
        }
    }

    @Test func localEditingAndTabs() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ViewerTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.txt")
        try Data("original".utf8).write(to: url)
        let files = FilesStore()
        let editor = files.activeEditor
        let connections = RemoteConnectionStore()
        let location = FileLocation.local(url)
        files.preview(location, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        #expect(editor.remote.states.isEmpty)
        let localFile = try #require(editor.local.fileStores[location])
        let file = localFile.document
        #expect(file.isEditable)
        file.updateReadOnly(source: "must not replace local content")
        #expect(file.textStorage.string == "original")
        file.content = .text("edited")
        #expect(file.hasUnsavedChanges)
        files.open(location, hosts: [], connections: connections, servers: RemoteServerStore(connections: connections))
        #expect(editor.local.fileStores[location] === localFile)
        try localFile.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
        #expect(!file.hasUnsavedChanges)
        #expect(editor.previewTab == nil)
        editor.close(.file(location))
        #expect(editor.tabs.isEmpty)
        #expect(editor.selectedTab == nil)
    }
}

// Keep focus tests independent of the user's foreground application.
@MainActor private final class EditorFocusTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private struct ViewerFixture {
    let container: ModelContainer
    let first: RemoteHost
    let second: RemoteHost
    init() throws {
        container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.autosaveEnabled = false
        let hosts = HostStore(context: container.mainContext)
        first = try hosts.addRemote(name: "one", basePath: "/same", hostname: "unused", user: "test", identityFile: "")
        second = try hosts.addRemote(name: "two", basePath: "/same", hostname: "unused", user: "test", identityFile: "")
    }
    func root(second: Bool = false) -> FileLocation {
        .remote(hostID: (second ? self.second : first).persistentModelID, path: "/project")
    }
}

@MainActor private final class ViewerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
