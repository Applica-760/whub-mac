// テスト一覧:
// - markdownPreviewReusesDocumentsAndTracksEachOpenFile(): [MD-F-005]
// - fileEncodingPreservesLineEndingsAndBOM(): 改行形式とBOMを保持する。
// - fileEncodingAcceptsEmptyUTF8AndRejectsInvalidBytes(): 空UTF-8の受理と不正バイトの拒否。
// - remoteImageRetainsPreviewAcrossFailureAndReconnect(): 画像取得・再読込・切断時の表示を確認する。
// - remoteImageRejectsInvalidData(): 不正な画像の取得失敗を確認する。
// - remoteSaveKeepsNewerEditsAndPreventsDuplicateSaves(): リモート保存中の新しい編集を保持し、重複保存を防ぐ。
// - remoteConflictAndFailedClosePreserveDraft(): リモート競合と閉鎖失敗時の下書き保持。
// - remoteLostSaveResponseIsReconciledBeforeRetry(): 応答不明の保存結果を再試行前に照合する。
// - remoteUndoAfterUnconfirmedSaveStillProtectsTab(): 保存結果不明のままUndoしてもタブを保護する。
// - remoteDirtyPreviewAndReconnectKeepDraft(): 未保存プレビューと再接続時の下書き保持。
// - remoteTracksByteChangesInCanonicallyEquivalentText(): 正規化で同値の文字列でもバイト差を検出する。
// - remoteSavePreservesBOMLineEndingsAndCloseWaitsForSuccess(): リモート保存のBOM・改行保持と成功後の閉鎖。
// - remoteReadsAndEdits(): リモート読込・編集・タブ操作。
// - lateResultAfterPreviewReplacement(): プレビュー置換後の遅い読込結果を無視する。
// - failureAndInvalidRoot(): 読込失敗と不正なルートの扱い。
// - refreshAndFailureRetainEditableFile(): 再読込と失敗時に編集可能な文書を保持する。
// - reconnectDiscardsOldSessionResult(): 再接続後に旧セッションの結果を無視する。
// - refreshAndCloseDiscardPendingResult(): 再読込・閉鎖後に保留中の結果を無視する。
// - localConflictPreservesEditsAndAdoptsLatest(): ローカル競合時に編集を保護し、最新内容を取り込む。
// - workspaceSwitchPreservesLocalTabsAndUnsavedContents(): Workspace切替でローカルタブと未保存内容を保持する。
// - remoteWorkspacesKeepSeparateTabsAndPendingReads(): Workspace別にリモートタブと保留読込を分離する。
// - localEditingAndTabs(): [TAB-F-008]
// - remoteDiffPreviewCanBeOpenedAndClosed(): リモート差分タブの操作。

import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
import WhubGit
import WhubClient
@testable import whub

@Suite @MainActor
struct EditorStoreTests {
    @Test func remoteImageRetainsPreviewAcrossFailureAndReconnect() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("graph.png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let first = NSObject()
        let second = NSObject()
        var connection: ObjectIdentifier? = ObjectIdentifier(first)
        let failure = NSMutableString(string: "")
        let editor = EditorStore()
        editor.remote.load(location, root: root, connection: { connection }, write: { _, _, _, _ in
            Issue.record("画像を保存してはいけません")
            return ""
        }, readImage: { rootPath, path in
            #expect(rootPath == "/project" && path == "graph.png")
            if failure.length > 0 { throw WhubClientError.api(status: 422, code: "image_too_large", message: "上限超過") }
            return data
        }) { _, _, _ in
            Issue.record("画像をテキストとして取得してはいけません")
            return ""
        }
        editor.open(.file(location))
        let remote = try #require(editor.remote.fileStores[location])
        try await waitForEditorTest { remote.image != nil }
        let original = try #require(remote.image)
        #expect(editor.selectedTab == .file(location))
        #expect(remote.document?.isEditable == false && !remote.canSave)
        failure.setString("上限超過")
        remote.refresh()
        try await waitForEditorTest { if case .failed = remote.state { return true }; return false }
        #expect(remote.image === original)
        connection = nil
        editor.remote.synchronizeConnections()
        if case .disconnected = remote.state {} else { Issue.record("切断状態になっていません") }
        #expect(remote.image === original)
        failure.setString("")
        connection = ObjectIdentifier(second)
        editor.remote.synchronizeConnections()
        try await waitForEditorTest { if case .loaded = remote.state { return remote.image !== original }; return false }
        editor.close(.file(location))
        #expect(editor.remote.fileStores[location] == nil)
    }

    @Test func remoteImageRejectsInvalidData() async throws {
        let fixture = try ViewerFixture()
        let root = fixture.root()
        let location = root.appending("invalid.png")
        let editor = RemoteEditorStore()
        editor.load(location, root: root, write: { _, _, _, text in text }, readImage: { _, _ in Data([0, 1]) }) { _, _, _ in "" }
        let remote = try #require(editor.fileStores[location])
        try await waitForEditorTest { if case .failed = remote.state { return true }; return false }
        #expect(remote.image == nil && remote.document == nil)
    }

    @Test func remoteDiffPreviewCanBeOpenedAndClosed() throws {
        let fixture = try ViewerFixture()
        let location = fixture.root().appending("file.txt")
        let files = FilesStore()
        files.openDiff(location, preview: true)
        #expect(files.activeEditor.selectedTab == .diff(location))
        #expect(files.activeEditor.previewTab == .diff(location))
        files.openDiff(location)
        #expect(files.activeEditor.previewTab == nil)
        files.activeEditor.close(.diff(location))
        #expect(files.activeEditor.tabs.isEmpty)
    }

    @Test func markdownPreviewReusesDocumentsAndTracksEachOpenFile() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/EditorTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileLocation.local(directory.appendingPathComponent("first.MD"))
        let second = FileLocation.local(directory.appendingPathComponent("second.md"))
        let plain = FileLocation.local(directory.appendingPathComponent("plain.txt"))
        let binary = FileLocation.local(directory.appendingPathComponent("binary.md"))
        for location in [first, second, plain] { try Data("# Saved".utf8).write(to: #require(location.localURL)) }
        try Data([0, 255]).write(to: #require(binary.localURL))
        let files = FilesStore()
        let editor = files.activeEditor
        files.openMarkdownPreview(first)
        let document = try #require(editor.file(for: first))
        #expect(editor.selectedTab == .file(first) && editor.previewTab == nil)
        #expect(editor.markdownPreviewLocation == first && editor.markdownPreviews == [first])
        document.content = .text("# Unsaved")
        editor.setMarkdownPreviewVisible(false, for: first)
        files.openMarkdownPreview(first)
        #expect(editor.file(for: first) === document && document.hasUnsavedChanges)
        if case let .text(source) = document.content { #expect(source == "# Unsaved") }
        else { Issue.record("Markdown source must remain editable text") }
        files.openMarkdownPreview(second)
        #expect(editor.markdownPreviews == [first, second])
        editor.setMarkdownPreviewVisible(false, for: first)
        #expect(editor.markdownPreviews == [second])
        editor.close(.file(second))
        #expect(editor.markdownPreviews.isEmpty)
        files.openMarkdownPreview(plain)
        #expect(!editor.tabs.contains(.file(plain)))
        files.openMarkdownPreview(binary)
        #expect(editor.markdownPreviewLocation == nil && !editor.markdownPreviews.contains(binary))
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
        try await waitForEditorTest { editor.remote.file(for: location) != nil }
        let remote = try #require(editor.remote.fileStores[location])
        let file = try #require(remote.document)
        #expect(file.isEditable && file.saveAction != nil && file.canSave?() == true)
        edit(file, "submitted")
        let saving = Task { await remote.save() }
        try await waitForEditorTest { gate.waiting }
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
        try await waitForEditorTest { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "draft")
        disk = "external"
        #expect(await remote.confirmClose(choice: .save) == false)
        #expect(disk == "external" && file.savedSource == "original")
        #expect(file.hasUnsavedChanges && remote.message != nil)
        remote.refresh()
        try await waitForEditorTest { if case .loaded = remote.state { return true }; return false }
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
        try await waitForEditorTest { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "submitted")
        #expect(await remote.save() == false)
        #expect(!remote.canSave && file.hasUnsavedChanges)
        #expect(await remote.save() == false)
        #expect(writes == 1)
        edit(file, "newer edit")
        remote.refresh()
        try await waitForEditorTest { if case .loaded = remote.state { return remote.canSave }; return false }
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
        try await waitForEditorTest { editor.remote.file(for: location) != nil }
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
        try await waitForEditorTest { if case .loaded = remote.state { return true }; return false }
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
        try await waitForEditorTest { editor.remote.file(for: location) != nil }
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
        try await waitForEditorTest { if case .loaded = remote.state { return true }; return false }
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
        try await waitForEditorTest { store.file(for: location) != nil }
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
        try await waitForEditorTest { store.file(for: location) != nil }
        let remote = try #require(store.fileStores[location])
        let file = try #require(remote.document)
        edit(file, "日本語\nnext\n")
        #expect(await remote.confirmClose(choice: .save))
        #expect(disk.utf8.elementsEqual("\u{FEFF}日本語\r\nnext\r\n".utf8))
        #expect(!file.hasUnsavedChanges)
        remote.refresh()
        try await waitForEditorTest { remote.canSave }
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
        try await waitForEditorTest { editor.remote.file(for: location) != nil }
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
        try await waitForEditorTest { file.editorViews.views["remote"] != nil }
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
        try await waitForEditorTest { editor.remote.file(for: other) != nil }
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
        try await waitForEditorTest { gate.waiting }
        editor.remote.load(next, root: root, write: { _, _, _, text in text }) { _, _, _ in "next" }
        editor.preview(.file(next))
        #expect(editor.remote.states[old] == nil)
        editor.remote.load(old, root: root, write: { _, _, _, text in text }) { _, _, _ in "new" }
        editor.open(.file(old))
        try await waitForEditorTest { editor.remote.file(for: old) != nil }
        gate.release()
        try await waitForEditorTest { returned }
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
        try await waitForEditorTest { if case .failed = store.states[file] { return true }; return false }
        for location in [root.appending("../outside"), fixture.root(second: true).appending("file")] {
            store.load(location, root: root, write: { _, _, _, text in text }) { _, _, _ in
                Issue.record("不正なルートで取得が実行された")
                return "wrong"
            }
            guard case .failed = store.states[location] else { Issue.record("エラーが必要"); return }
        }
        store.close(file)
        store.load(file, root: root, write: { _, _, _, text in text }) { _, _, _ in "" }
        try await waitForEditorTest { store.file(for: file) != nil }
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
        try await waitForEditorTest { editor.remote.file(for: location) != nil }
        let file = try #require(editor.remote.file(for: location))
        editor.refresh()
        try await waitForEditorTest { file.textStorage.string == "second" }
        #expect(editor.remote.file(for: location) === file)
        #expect(editor.selectedTab == .file(location))
        #expect(file.isEditable)
        editor.refresh()
        try await waitForEditorTest { if case .failed = editor.remote.states[location] { return true }; return false }
        #expect(file.textStorage.string == "second")
        #expect(editor.remote.file(for: location) === file)
        editor.refresh()
        try await waitForEditorTest { file.textStorage.string.isEmpty }
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
        try await waitForEditorTest { store.file(for: location) != nil }
        let file = try #require(store.file(for: location))
        store.refresh()
        try await waitForEditorTest { gate.waiting }
        session = nil
        store.synchronizeConnections()
        guard case .disconnected = store.states[location] else { Issue.record("切断状態が必要"); return }
        #expect(file.textStorage.string == "cached")
        store.refresh()
        #expect(reads == 2)
        session = ObjectIdentifier(secondSession)
        store.synchronizeConnections()
        try await waitForEditorTest { file.textStorage.string == "new session" }
        gate.release()
        try await waitForEditorTest { returned }
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
        try await waitForEditorTest { gate.waiting }
        store.refresh()
        try await waitForEditorTest { store.file(for: location)?.textStorage.string == "latest" }
        store.close(location)
        gate.release()
        try await waitForEditorTest { returned }
        #expect(store.states[location] == nil)
        #expect(store.file(for: location) == nil)
        store.refresh()
        #expect(reads == 2)
    }

    @Test func localConflictPreservesEditsAndAdoptsLatest() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

    @Test func workspaceSwitchPreservesLocalTabsAndUnsavedContents() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        try await waitForEditorTest { gate.waiting }
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
        try await waitForEditorTest { firstEditor.file(for: firstFile) != nil }
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
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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

    private func edit(_ file: FileStore, _ source: String) {
        file.textStorage.replaceCharacters(in: NSRange(location: 0, length: file.textStorage.length), with: source)
        file.content = .text(source)
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
