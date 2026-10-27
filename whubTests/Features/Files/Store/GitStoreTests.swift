import AppKit
import SwiftUI
import Foundation
import Testing
import WhubCore
import WhubGit
@testable import whub

@Suite @MainActor
struct GitStoreTests {
    @Test func diffUsesFilesOwnRepositoryAndSurvivesDeletedParent() async throws {
        let fixture = try GitTestFixture()
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
        let diff = try #require(files.activeEditor.local.diffStores[file])
        try await waitForGitTest { !diff.isLoading }
        #expect(diff.diff?.content == .text(before: "before\n", after: "after\n"))
        files.activeEditor.close(.diff(.local(file)))
        try FileManager.default.removeItem(at: parent)
        files.openDiff(.local(file))
        let deleted = try #require(files.activeEditor.local.diffStores[file])
        try await waitForGitTest { !deleted.isLoading }
        #expect(deleted.diff?.content == .text(before: "before\n", after: ""))
        files.activeEditor.close(.diff(.local(file)))
        files.explorer.localTree.reset()
    }

    @Test func diffTabsPreserveUnsavedEditorAndPreviewLifecycle() async throws {
        let fixture = try GitTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        files.explorer.localTree.setRoot(fixture.first)
        let location = FileLocation.local(fixture.firstFile)
        files.preview(location, hosts: [], connections: RemoteConnectionStore(), servers: RemoteServerStore(connections: RemoteConnectionStore()))
        let document = try #require(files.activeEditor.file(for: location))
        document.content = .text("unsaved")
        files.openDiff(location, preview: true)
        let diff = try #require(files.activeEditor.local.diffStores[fixture.firstFile])
        try await waitForGitTest { !diff.isLoading }
        #expect(diff.diff?.content == .text(before: "", after: "original\n"))
        #expect(files.activeEditor.tabs == [.file(location), .diff(.local(fixture.firstFile))])
        #expect(files.activeEditor.previewTab == .diff(.local(fixture.firstFile)))
        #expect(document.hasUnsavedChanges)
        files.openDiff(location)
        #expect(files.activeEditor.previewTab == nil)
        files.openDiff(.local(fixture.secondFile), preview: true)
        #expect(files.activeEditor.previewTab == .diff(.local(fixture.secondFile)))
        files.openDiff(location, preview: true)
        #expect(files.activeEditor.selectedTab == .diff(.local(fixture.firstFile)))
        #expect(files.activeEditor.previewTab == .diff(.local(fixture.secondFile)))
        files.activeEditor.close(.diff(.local(fixture.firstFile)))
        #expect(files.activeEditor.file(for: location) === document)
        #expect(files.activeEditor.local.diffStores[fixture.firstFile] == nil)
        files.activeEditor.close(.diff(.local(fixture.secondFile)))
        document.content = .text("original\n")
        files.activeEditor.close(.file(location))
        #expect(files.activeEditor.tabs.isEmpty)
        files.explorer.localTree.reset()
    }

    @Test func diffFollowsSaveCommitDeletionAndExplorerRootSwitch() async throws {
        let fixture = try GitTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "baseline"], at: fixture.first)
        let files = FilesStore()
        files.git.setDiffEnabled(true)
        files.explorer.localTree.setRoot(fixture.first)
        let location = FileLocation.local(fixture.firstFile)
        files.openDiff(location)
        let diff = try #require(files.activeEditor.local.diffStores[fixture.firstFile])
        try await waitForGitTest { diff.diff != nil && !files.git.isLoadingDiff }
        #expect(diff.diff?.change == nil)
        files.open(location, hosts: [], connections: RemoteConnectionStore(), servers: RemoteServerStore(connections: RemoteConnectionStore()))
        let local = try #require(files.activeEditor.local.fileStores[location])
        local.document.content = .text("saved\n")
        try local.save()
        try await waitForGitTest {
            diff.diff?.content == .text(before: "original\n", after: "saved\n")
                && files.git.diffChanges[fixture.firstFile] == .modified
        }
        try fixture.git(["add", "."], at: fixture.first)
        try fixture.git(["commit", "-qm", "saved"], at: fixture.first)
        try await waitForGitTest {
            diff.diff?.content == .text(before: "saved\n", after: "saved\n") && files.git.diffChanges.isEmpty
        }
        files.explorer.localTree.setRoot(fixture.second)
        try await waitForGitTest { files.git.diffChanges[fixture.secondFile] == .added }
        try FileManager.default.removeItem(at: fixture.firstFile)
        try await waitForGitTest { diff.diff?.change == .deleted }
        #expect(diff.diff?.content == .text(before: "saved\n", after: ""))
        #expect(files.git.diffChanges[fixture.firstFile] == nil)
        files.refresh()
        try await waitForGitTest { !diff.isLoading }
        #expect(diff.diff?.change == .deleted)
        files.activeEditor.close(.file(location))
        files.activeEditor.close(.diff(.local(fixture.firstFile)))
        files.explorer.localTree.reset()
    }

    @Test func diffListOmitsIndexOnlyChangesAndDiscardsOldRoot() async throws {
        let fixture = try GitTestFixture()
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
        try await waitForGitTest { !git.isLoadingDiff }
        #expect(git.changes[fixture.firstFile] == .modified)
        #expect(git.diffChanges.isEmpty)
        git.refresh()
        git.setRoot(fixture.second)
        git.refresh()
        try await waitForGitTest { git.diffChanges[fixture.secondFile] == .added }
        #expect(git.diffChanges[fixture.firstFile] == nil)
        git.setRoot(fixture.first.appendingPathComponent(".git"))
        git.refresh()
        try await waitForGitTest { !git.isLoadingDiff }
        #expect(!git.isRepository)
        #expect(git.diffChanges.isEmpty)
        git.stop()
    }

    @Test func closedAndFailedDiffsDoNotPublishOldContent() async throws {
        let fixture = try GitTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        files.openDiff(.local(fixture.firstFile), preview: true)
        let first = try #require(files.activeEditor.local.diffStores[fixture.firstFile])
        files.openDiff(.local(fixture.secondFile), preview: true)
        #expect(files.activeEditor.local.diffStores[fixture.firstFile] == nil)
        let second = try #require(files.activeEditor.local.diffStores[fixture.secondFile])
        try await waitForGitTest { !second.isLoading }
        #expect(first.diff == nil)
        #expect(second.diff?.fileURL == fixture.secondFile)
        files.activeEditor.close(.diff(.local(fixture.secondFile)))
        let failed = LocalDiffStore(fileURL: fixture.secondFile, directory: fixture.first)
        try await waitForGitTest { !failed.isLoading }
        #expect(failed.errorMessage != nil)
        #expect(failed.diff == nil)
        failed.stop()
    }

    @Test func rootSwitchDiscardsInFlightStatus() async throws {
        let fixture = try GitTestFixture()
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
        try await waitForGitTest { store.changes[fixture.secondFile] == .added }
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
        let fixture = try GitTestFixture()
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
}
