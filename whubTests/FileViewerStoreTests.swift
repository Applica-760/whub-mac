// 検証内容: 本文の遅延取得・再利用、ホスト識別、ルート検証、失敗表示、閉じたタブへの遅延応答破棄。
// 読み取り専用の編集・保存拒否と、ローカルの保存・プレビュー・タブ操作も確認する。
// 限界: 通信は制御した応答を使用。実SSH・画面操作・切断後の再取得は別途確認する。
import AppKit
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct FileViewerStoreTests {
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RemoteSessionError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func remoteReadsAndReadOnly() async throws {
        let fixture = try ViewerFixture()
        let viewer = FileViewerStore()
        let root = fixture.root()
        let location = root.appending("src/a.swift")
        var requests = 0
        viewer.remote.load(location, root: root) { _, rootPath, path in
            #expect(rootPath == "/project")
            #expect(path == "src/a.swift")
            requests += 1
            return "let 日本語 = 1\n"
        }
        viewer.preview(location)
        viewer.remote.load(location, root: root) { _, _, _ in
            Issue.record("重複取得")
            return "wrong"
        }
        try await eventually { viewer.remote.file(for: location) != nil }
        let file = try #require(viewer.remote.file(for: location))
        #expect(file.textStorage.string == "let 日本語 = 1\n")
        #expect(requests == 1)
        #expect(!file.isEditable)
        #expect(!file.hasUnsavedChanges)
        #expect(!file.saveWithConfirmation())
        #expect(throws: FileStore.SaveError.self) { try file.save() }
        #expect(throws: FileStore.SaveError.self) { try file.adoptLatest() }
        file.checkForExternalChanges()
        #expect(file.diskMessage == nil)
        let content = CodeTextContent(state: file, editorID: "readonly", onEdit: {}, source: file.textStorage.string,
                                      language: "swift", hunks: [])
        let renderer = NSHostingView(rootView: content)
        renderer.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        renderer.layoutSubtreeIfNeeded()
        try await eventually { file.editorViews["readonly"] != nil }
        let text = try #require(file.editorViews["readonly"]?.documentView as? CodeTextView)
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(!text.validateMenuItem(NSMenuItem(title: "Save", action: #selector(CodeTextView.saveDocument(_:)), keyEquivalent: "s")))
        viewer.open(location)
        #expect(viewer.previewLocation == nil)
        let otherRoot = fixture.root(second: true)
        let other = otherRoot.appending("src/a.swift")
        viewer.remote.load(other, root: otherRoot) { _, _, _ in "other" }
        viewer.open(other)
        try await eventually { viewer.remote.file(for: other) != nil }
        #expect(viewer.fileLocations == [location, other])
        #expect(viewer.remote.file(for: other)?.textStorage.string == "other")
        viewer.move(other, before: location)
        #expect(viewer.fileLocations == [other, location])
        viewer.close(location)
        viewer.close(other)
        #expect(viewer.remote.states.isEmpty)
    }

    @Test(arguments: [true, false])
    func lateResultAfterPreviewReplacement(succeeds: Bool) async throws {
        let fixture = try ViewerFixture()
        let viewer = FileViewerStore()
        let root = fixture.root()
        let old = root.appending("old")
        let next = root.appending("next")
        let gate = ViewerGate()
        var returned = false
        viewer.remote.load(old, root: root) { _, _, _ in
            await gate.wait()
            returned = true
            if succeeds { return "old" }
            throw RemoteSessionError.disconnected
        }
        viewer.preview(old)
        try await eventually { gate.waiting }
        viewer.remote.load(next, root: root) { _, _, _ in "next" }
        viewer.preview(next)
        #expect(viewer.remote.states[old] == nil)
        viewer.remote.load(old, root: root) { _, _, _ in "new" }
        viewer.open(old)
        try await eventually { viewer.remote.file(for: old) != nil }
        gate.release()
        try await eventually { returned }
        #expect(viewer.remote.file(for: old)?.textStorage.string == "new")
        #expect(viewer.selectedLocation == old)
        viewer.close(old)
        viewer.close(next)
    }

    @Test func failureAndInvalidRoot() async throws {
        let fixture = try ViewerFixture()
        let store = RemoteFileViewerStore()
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

    @Test func localEditingAndTabs() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ViewerTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.txt")
        try Data("original".utf8).write(to: url)
        let viewer = FileViewerStore()
        let location = FileLocation.local(url)
        viewer.preview(location)
        let file = try #require(viewer.fileStores[location])
        #expect(file.isEditable)
        file.content = .text("edited")
        #expect(file.hasUnsavedChanges)
        viewer.open(location)
        try file.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
        #expect(!file.hasUnsavedChanges)
        #expect(viewer.previewLocation == nil)
        viewer.close(location)
        #expect(viewer.fileLocations.isEmpty)
        #expect(viewer.selectedLocation == nil)
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
