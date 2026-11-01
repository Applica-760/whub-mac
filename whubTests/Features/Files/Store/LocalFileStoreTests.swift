import AppKit
import Foundation
import Testing
@testable import whub

@Suite @MainActor
struct LocalFileStoreTests {
    private func fixture() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/LocalFileTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func saveKeepsLaterEditsAndPreservesSymlinkAndEncoding() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try Data("\u{FEFF}original\r\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let queue = DispatchQueue(label: "test.file-save")
        let file = LocalFileStore(fileURL: link, io: LocalFileIO(queue: queue))
        defer { file.stop() }
        try await waitForEditorTest { !file.isLoading }
        file.document.content = .text("first edit\n")
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let save = Task { await file.confirmClose(choice: .save) }
        try await waitForEditorTest { file.isSaving }
        file.document.content = .text("later edit\n")
        queue.resume(); suspended = false
        #expect(await save.value == false)
        #expect(try Data(contentsOf: target) == Data("\u{FEFF}first edit\r\n".utf8))
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(file.document.savedSource == "first edit\n")
        #expect(file.document.hasUnsavedChanges)
        if case .text(let source) = file.document.content { #expect(source == "later edit\n") }
        else { Issue.record("Later edits must survive save") }
        #expect(await file.confirmClose(choice: .save))
    }

    @Test func adoptingLatestDoesNotOverwriteAnEditMadeDuringRead() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file")
        try Data("original".utf8).write(to: url)
        let queue = DispatchQueue(label: "test.file-adopt")
        let file = LocalFileStore(fileURL: url, io: LocalFileIO(queue: queue))
        defer { file.stop() }
        try await waitForEditorTest { !file.isLoading }
        try Data("external".utf8).write(to: url)
        queue.suspend()
        var suspended = true
        defer { if suspended { queue.resume() } }
        let adopt = Task { try await file.adoptLatest() }
        try await waitForEditorTest { file.isSaving }
        file.document.content = .text("new edit")
        queue.resume(); suspended = false
        await #expect(throws: LocalFileStore.SaveError.self) { try await adopt.value }
        #expect(file.document.savedSource == "original")
        #expect(file.document.hasUnsavedChanges)
    }

    @Test func loadingCanBeClosedWithoutWaitingForDisk() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file")
        try Data("original".utf8).write(to: url)
        let queue = DispatchQueue(label: "test.file-load")
        queue.suspend()
        let file = LocalFileStore(fileURL: url, io: LocalFileIO(queue: queue))
        #expect(file.isLoading)
        file.stop()
        queue.resume()
        try await Task.sleep(for: .milliseconds(30))
        #expect(file.document.savedSource == nil)
    }

    @Test func inputCommitUsesCachedExternalContentWithoutReadingAgain() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file")
        try Data("original".utf8).write(to: url)
        let file = LocalFileStore(fileURL: url)
        defer { file.stop() }
        try await waitForEditorTest { !file.isLoading }
        let text = MarkedTextView()
        let scroll = NSScrollView()
        scroll.documentView = text
        file.document.editorViews.views["ime"] = scroll
        text.marked = true
        try Data("external".utf8).write(to: url)
        file.checkForExternalChanges()
        try await waitForEditorTest { file.diskMessage != nil }
        #expect(file.document.savedSource == "original")
        // A second disk read would fail; committing input must use the already observed content.
        try FileManager.default.removeItem(at: url)
        text.marked = false
        file.document.onContentChange?()
        try await waitForEditorTest { file.document.savedSource == "external" }
        #expect(file.diskMessage == nil)
    }
}

@MainActor private final class MarkedTextView: NSTextView {
    var marked = false
    override func hasMarkedText() -> Bool { marked }
}
