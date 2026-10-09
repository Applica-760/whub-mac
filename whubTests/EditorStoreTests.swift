// 検証内容: 本文の遅延取得・再利用、ホスト識別、ルート検証、失敗表示、閉じたタブへの遅延応答破棄。
// 読み取り専用の編集・保存拒否と、ローカルの保存・プレビュー・タブ操作も確認する。
// リロード・切断・再接続・取得失敗時の旧本文保持と、旧セッションの応答破棄も確認する。
// 限界: 通信と接続識別は制御した値を使用。実SSH・画面操作は別途確認する。
import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct EditorStoreTests {
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
            guard ContinuousClock.now < deadline else { throw RemoteSessionError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func remoteReadsAndReadOnly() async throws {
        let fixture = try ViewerFixture()
        let editor = EditorStore()
        let root = fixture.root()
        let location = root.appending("src/a.swift")
        var requests = 0
        editor.remote.load(location, root: root) { _, rootPath, path in
            #expect(rootPath == "/project")
            #expect(path == "src/a.swift")
            requests += 1
            return "let 日本語 = 1\n"
        }
        editor.preview(.file(location))
        editor.remote.load(location, root: root) { _, _, _ in
            Issue.record("重複取得")
            return "wrong"
        }
        try await eventually { editor.remote.file(for: location) != nil }
        let file = try #require(editor.remote.file(for: location))
        #expect(file.textStorage.string == "let 日本語 = 1\n")
        #expect(requests == 1)
        #expect(!file.isEditable)
        #expect(!file.hasUnsavedChanges)
        #expect(file.saveAction == nil)
        #expect(file.canSave == nil)
        let content = CodeEditorView(state: file, editorID: "readonly", onEdit: {}, source: file.textStorage.string,
                                      language: "swift", hunks: [])
        let renderer = NSHostingView(rootView: content)
        renderer.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        renderer.layoutSubtreeIfNeeded()
        try await eventually { file.editorViews.views["readonly"] != nil }
        let text = try #require(file.editorViews.views["readonly"]?.documentView as? CodeTextView)
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(!text.validateMenuItem(NSMenuItem(title: "Save", action: #selector(CodeTextView.saveDocument(_:)), keyEquivalent: "s")))
        editor.open(.file(location))
        #expect(editor.previewTab == nil)
        let otherRoot = fixture.root(second: true)
        let other = otherRoot.appending("src/a.swift")
        editor.remote.load(other, root: otherRoot) { _, _, _ in "other" }
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
        editor.remote.load(old, root: root) { _, _, _ in
            await gate.wait()
            returned = true
            if succeeds { return "old" }
            throw RemoteSessionError.disconnected
        }
        editor.preview(.file(old))
        try await eventually { gate.waiting }
        editor.remote.load(next, root: root) { _, _, _ in "next" }
        editor.preview(.file(next))
        #expect(editor.remote.states[old] == nil)
        editor.remote.load(old, root: root) { _, _, _ in "new" }
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
        store.load(file, root: root) { _, _, _ in throw RemoteSessionError.disconnected }
        try await eventually { if case .failed = store.states[file] { return true }; return false }
        for location in [root.appending("../outside"), fixture.root(second: true).appending("file")] {
            store.load(location, root: root) { _, _, _ in
                Issue.record("不正なルートで取得が実行された")
                return "wrong"
            }
            guard case .failed = store.states[location] else { Issue.record("エラーが必要"); return }
        }
        store.close(file)
        store.load(file, root: root) { _, _, _ in "" }
        try await eventually { store.file(for: file) != nil }
        #expect(store.file(for: file)?.textStorage.string == "")
    }

    @Test func refreshAndFailureRetainReadOnlyFile() async throws {
        let fixture = try ViewerFixture()
        let editor = EditorStore()
        let root = fixture.root()
        let location = root.appending("file")
        var reads = 0
        editor.remote.load(location, root: root) { _, rootPath, path in
            #expect(rootPath == "/project")
            #expect(path == "file")
            reads += 1
            switch reads {
            case 1: return "first"
            case 2: return "second"
            case 3: throw RemoteSessionError.remote(-32000, "ファイルが削除されました")
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
        #expect(!file.isEditable)
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
        store.load(location, root: root, connection: { session }) { _, _, _ in
            reads += 1
            if reads == 1 { return "cached" }
            if reads == 2 {
                await gate.wait()
                returned = true
                if succeeds { return "old session" }
                throw RemoteSessionError.disconnected
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
        store.load(location, root: root) { _, _, _ in
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
        let editor = files.editor
        let connections = RemoteConnectionStore()
        let location = FileLocation.local(url)
        files.open(location, hosts: [], connections: connections)
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

    @Test func localEditingAndTabs() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ViewerTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.txt")
        try Data("original".utf8).write(to: url)
        let files = FilesStore()
        let editor = files.editor
        let connections = RemoteConnectionStore()
        let location = FileLocation.local(url)
        files.preview(location, hosts: [], connections: connections)
        #expect(editor.remote.states.isEmpty)
        let localFile = try #require(editor.local.fileStores[location])
        let file = localFile.document
        #expect(file.isEditable)
        file.updateReadOnly(source: "must not replace local content")
        #expect(file.textStorage.string == "original")
        file.content = .text("edited")
        #expect(file.hasUnsavedChanges)
        files.open(location, hosts: [], connections: connections)
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
