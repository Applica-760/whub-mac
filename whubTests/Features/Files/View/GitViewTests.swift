import AppKit
import SwiftUI
import Foundation
import Testing
import WhubCore
import WhubGit
@testable import whub

@Suite @MainActor
struct GitViewTests {
    @Test func reloadUpdatesDisplayedDiffAfterCommit() async throws {
        let fixture = try GitTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let files = FilesStore()
        let location = FileLocation.local(fixture.firstFile)
        files.open(location, hosts: [], connections: RemoteConnectionStore(), servers: RemoteServerStore(connections: RemoteConnectionStore()))
        let document = try #require(files.activeEditor.file(for: location))
        let host = NSHostingView(rootView: EditorView()
            .environmentObject(files).environmentObject(files.activeEditor).environmentObject(files.git))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(host) {} }
        try await waitForGitTest {
            document.editorViews.views.values.contains {
                ($0.verticalRulerView as? LineNumberRulerView)?.hunks.isEmpty == false
            }
        }
        let ruler = try #require(document.editorViews.views.values.first?.verticalRulerView as? LineNumberRulerView)
        for arguments in [["add", "first.swift"], ["commit", "--quiet", "-m", "baseline"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", fixture.first.path, "-c", "user.name=Test",
                                 "-c", "user.email=test@example.invalid"] + arguments
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let diskRevision = try #require(files.activeEditor.local.fileStores[location]).diskRevision
        files.refresh()
        try await waitForGitTest { ruler.hunks.isEmpty }
        #expect(files.activeEditor.local.fileStores[location]?.diskRevision == diskRevision)
        files.activeEditor.close(.file(location))
    }
}
