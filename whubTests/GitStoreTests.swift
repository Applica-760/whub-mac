import AppKit
import SwiftUI
import Foundation
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct GitStoreTests {
    @Test func diffUsesFilesOwnRepositoryAndSurvivesDeletedParent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.first.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("file.swift")
        try Data("before\n".utf8).write(to: file)
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "baseline"], at: fixture.first)
        try Data("after\n".utf8).write(to: file)
        let files = FilesStore()
        files.explorer.localTree.setRoot(fixture.directory)
        files.openDiff(.local(file))
        let diff = try #require(files.editor.local.diffStores[file])
        try await eventually { !diff.isLoading }
        #expect(diff.diff?.content == .text(before: "before\n", after: "after\n"))
        files.editor.close(.diff(file))
        try FileManager.default.removeItem(at: parent)
        files.openDiff(.local(file))
        let deleted = try #require(files.editor.local.diffStores[file])
        try await eventually { !deleted.isLoading }
        #expect(deleted.diff?.content == .text(before: "before\n", after: ""))
        files.editor.close(.diff(file))
        files.explorer.localTree.reset()
    }

    @Test func diffExplorerPreviewsDeletedFilesAndContextMenuOpensClickedRow() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "baseline"], at: fixture.first)
        try FileManager.default.removeItem(at: fixture.firstFile)
        let added = fixture.first.appendingPathComponent("z.swift")
        try Data("new\n".utf8).write(to: added)
        let files = FilesStore()
        files.git.setDiffEnabled(true)
        files.explorer.localTree.setRoot(fixture.first)
        let host = NSHostingView(rootView: ExplorerDiffView(git: files.git, editor: files.editor,
            onPreview: { files.openDiff($0, preview: true) }, onOpen: { files.openDiff($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await eventually {
            host.layoutSubtreeIfNeeded()
            return table(in: host)?.numberOfRows == 2
        }
        let list = try #require(table(in: host))
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(files.editor.previewTab == .diff(fixture.firstFile))
        let deleted = try #require(files.editor.local.diffStores[fixture.firstFile])
        try await eventually { !deleted.isLoading }
        #expect(deleted.diff?.content == .text(before: "original\n", after: ""))
        let point = list.convert(NSPoint(x: 10, y: list.rect(ofRow: 1).midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(list.menu(for: event))
        menu.performActionForItem(at: 2)
        #expect(files.editor.selectedTab == .diff(added))
        #expect(files.editor.previewTab != .diff(added))
        #expect(files.editor.local.fileStores.isEmpty)
        files.explorer.localTree.setRoot(fixture.second)
        try await eventually {
            host.layoutSubtreeIfNeeded()
            return files.git.diffChanges[fixture.secondFile] == .added && table(in: host)?.numberOfRows == 1
        }
        #expect(table(in: host)?.selectedRow == -1)
        files.editor.close(.diff(fixture.firstFile))
        files.editor.close(.diff(added))
        files.explorer.localTree.reset()
        withExtendedLifetime(host) {}
    }

    @Test func diffTabsPreserveUnsavedEditorAndPreviewLifecycle() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        files.explorer.localTree.setRoot(fixture.first)
        let location = FileLocation.local(fixture.firstFile)
        files.preview(location, hosts: [], connections: RemoteConnectionStore())
        let document = try #require(files.editor.file(for: location))
        document.content = .text("unsaved")
        files.openDiff(location, preview: true)
        let diff = try #require(files.editor.local.diffStores[fixture.firstFile])
        try await eventually { !diff.isLoading }
        #expect(diff.diff?.content == .text(before: "", after: "original\n"))
        #expect(files.editor.tabs == [.file(location), .diff(fixture.firstFile)])
        #expect(files.editor.previewTab == .diff(fixture.firstFile))
        #expect(document.hasUnsavedChanges)
        files.openDiff(location)
        #expect(files.editor.previewTab == nil)
        files.openDiff(.local(fixture.secondFile), preview: true)
        #expect(files.editor.previewTab == .diff(fixture.secondFile))
        files.openDiff(location, preview: true)
        #expect(files.editor.selectedTab == .diff(fixture.firstFile))
        #expect(files.editor.previewTab == .diff(fixture.secondFile))
        files.editor.close(.diff(fixture.firstFile))
        #expect(files.editor.file(for: location) === document)
        #expect(files.editor.local.diffStores[fixture.firstFile] == nil)
        files.editor.close(.diff(fixture.secondFile))
        document.content = .text("original\n")
        files.editor.close(.file(location))
        #expect(files.editor.tabs.isEmpty)
        files.explorer.localTree.reset()
    }

    @Test func diffFollowsSaveCommitDeletionAndExplorerRootSwitch() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "baseline"], at: fixture.first)
        let files = FilesStore()
        files.git.setDiffEnabled(true)
        files.explorer.localTree.setRoot(fixture.first)
        let location = FileLocation.local(fixture.firstFile)
        files.openDiff(location)
        let diff = try #require(files.editor.local.diffStores[fixture.firstFile])
        try await eventually { diff.diff != nil && !files.git.isLoadingDiff }
        #expect(diff.diff?.change == nil)
        files.open(location, hosts: [], connections: RemoteConnectionStore())
        let local = try #require(files.editor.local.fileStores[location])
        local.document.content = .text("saved\n")
        try local.save()
        try await eventually {
            diff.diff?.content == .text(before: "original\n", after: "saved\n")
                && files.git.diffChanges[fixture.firstFile] == .modified
        }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "saved"], at: fixture.first)
        try await eventually {
            diff.diff?.content == .text(before: "saved\n", after: "saved\n") && files.git.diffChanges.isEmpty
        }
        files.explorer.localTree.setRoot(fixture.second)
        try await eventually { files.git.diffChanges[fixture.secondFile] == .added }
        try FileManager.default.removeItem(at: fixture.firstFile)
        try await eventually { diff.diff?.change == .deleted }
        #expect(diff.diff?.content == .text(before: "saved\n", after: ""))
        #expect(files.git.diffChanges[fixture.firstFile] == nil)
        files.refresh()
        try await eventually { !diff.isLoading }
        #expect(diff.diff?.change == .deleted)
        files.editor.close(.file(location))
        files.editor.close(.diff(fixture.firstFile))
        files.explorer.localTree.reset()
    }

    @Test func diffListOmitsIndexOnlyChangesAndDiscardsOldRoot() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "baseline"], at: fixture.first)
        try Data("staged\n".utf8).write(to: fixture.firstFile)
        try fixture.git(["add", "."], at: fixture.first)
        try Data("original\n".utf8).write(to: fixture.firstFile)
        let git = GitStore()
        git.setDiffEnabled(true)
        git.setRoot(fixture.first)
        git.refresh()
        try await eventually { !git.isLoadingDiff }
        #expect(git.changes[fixture.firstFile] == .modified)
        #expect(git.diffChanges.isEmpty)
        git.refresh()
        git.setRoot(fixture.second)
        git.refresh()
        try await eventually { git.diffChanges[fixture.secondFile] == .added }
        #expect(git.diffChanges[fixture.firstFile] == nil)
        git.setRoot(fixture.first.appendingPathComponent(".git"))
        git.refresh()
        try await eventually { !git.isLoadingDiff }
        #expect(!git.isRepository)
        #expect(git.diffChanges.isEmpty)
        git.stop()
    }

    @Test func closedAndFailedDiffsDoNotPublishOldContent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        files.openDiff(.local(fixture.firstFile), preview: true)
        let first = try #require(files.editor.local.diffStores[fixture.firstFile])
        files.openDiff(.local(fixture.secondFile), preview: true)
        #expect(files.editor.local.diffStores[fixture.firstFile] == nil)
        let second = try #require(files.editor.local.diffStores[fixture.secondFile])
        try await eventually { !second.isLoading }
        #expect(first.diff == nil)
        #expect(second.diff?.fileURL == fixture.secondFile)
        files.editor.close(.diff(fixture.secondFile))
        let failed = LocalDiffStore(fileURL: fixture.secondFile, directory: fixture.first)
        try await eventually { !failed.isLoading }
        #expect(failed.errorMessage != nil)
        #expect(failed.diff == nil)
        failed.stop()
    }

    @Test func rootSwitchDiscardsInFlightStatus() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = GitStore()
        var switched = false
        store.onManagementDirectoriesChange = {
            if !switched {
                switched = true
                store.setRoot(fixture.second)
                store.refresh()
            }
        }
        store.setRoot(fixture.first)
        store.refresh()
        try await eventually { store.changes[fixture.secondFile] == .added }
        #expect(switched)
        #expect(store.rootURL == fixture.second)
        #expect(store.changes[fixture.firstFile] == nil)
        #expect(store.errorMessage == nil)
        #expect(store.managesStatus(for: fixture.secondFile))
        #expect(!store.managesStatus(for: fixture.firstFile))
        store.stop()
        #expect(!store.managesStatus(for: fixture.secondFile))
        #expect(store.changes[fixture.secondFile] == .added)
    }

    @Test func standaloneStatusAndLineDiffFollowCurrentContent() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let git = GitStore()
        let lines = GitLineStore()
        await lines.load(fileURL: fixture.firstFile, gitStore: git)
        #expect(git.changes[fixture.firstFile] == .added)
        #expect(lines.baseline?.source == "")
        #expect(lines.errorMessage == nil)
        await lines.update(source: "one\ntwo\n")
        let hunks = lines.hunks(for: fixture.firstFile, source: "one\ntwo\n")
        #expect(hunks.count == 1)
        #expect(hunks.first?.newLines == 0..<2)
        #expect(lines.hunks(for: fixture.secondFile, source: "one\ntwo\n").isEmpty)
        #expect(lines.hunks(for: fixture.firstFile, source: "changed\n").isEmpty)
        let pending = Task { await lines.update(source: "changed\n") }
        await Task.yield()
        pending.cancel()
        await pending.value
        #expect(lines.hunks(for: fixture.firstFile, source: "changed\n").isEmpty)
        await lines.load(fileURL: fixture.secondFile, gitStore: git)
        #expect(lines.hunks(for: fixture.firstFile, source: "one\ntwo\n").isEmpty)
        git.reset()
        #expect(git.changes.isEmpty)
    }

    @Test func reloadUpdatesDisplayedDiffAfterCommit() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        let location = FileLocation.local(fixture.firstFile)
        files.open(location, hosts: [], connections: RemoteConnectionStore())
        let document = try #require(files.editor.file(for: location))
        let host = NSHostingView(rootView: EditorView()
            .environmentObject(files).environmentObject(files.editor).environmentObject(files.git))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(host) {} }
        try await eventually {
            document.editorViews.values.contains {
                ($0.verticalRulerView as? LineNumberRulerView)?.hunks.isEmpty == false
            }
        }
        let ruler = try #require(document.editorViews.values.first?.verticalRulerView as? LineNumberRulerView)
        for arguments in [["add", "first.swift"], ["commit", "--quiet", "-m", "baseline"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", fixture.first.path, "-c", "user.name=Test",
                                 "-c", "user.email=test@example.invalid"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let diskRevision = try #require(files.editor.local.fileStores[location]).diskRevision
        files.refresh()
        try await eventually { ruler.hunks.isEmpty }
        #expect(files.editor.local.fileStores[location]?.diskRevision == diskRevision)
        files.editor.close(.file(location))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum FixtureError: Error { case gitFailed, timeout }

    private struct Fixture {
        let directory: URL
        let first: URL
        let second: URL
        let firstFile: URL
        let secondFile: URL

        func git(_ arguments: [String], at directory: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw FixtureError.gitFailed }
        }

        init() throws {
            let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            directory = project.appendingPathComponent("DerivedData/GitStoreTests/" + UUID().uuidString)
            first = directory.appendingPathComponent("first")
            second = directory.appendingPathComponent("second")
            firstFile = first.appendingPathComponent("first.swift")
            secondFile = second.appendingPathComponent("second.swift")
            do {
                for root in [first, second] {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["init", "--quiet", root.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw FixtureError.gitFailed }
                }
                try "original\n".write(to: firstFile, atomically: true, encoding: .utf8)
                try "second\n".write(to: secondFile, atomically: true, encoding: .utf8)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}
