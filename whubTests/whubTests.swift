//
//  whubTests.swift
//  whubTests
//
//  Created by 村上匠 on 2026/10/08.
//

import AppKit
import Combine
import SwiftData
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexCompletionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func completionsBelongToSecondAndFourthTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<3 { store.add() }
        let ids = store.sessions.map(\.id)
        var published: Set<CodexStore.ID> = []
        let observation = store.$completedSessionIDs.sink { published = $0 }
        defer { observation.cancel() }

        store.sessions[1].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1]])
        store.sessions[3].onCompletionChange?(true)
        #expect(store.completedSessionIDs == [ids[1], ids[3]])
        #expect(published == [ids[1], ids[3]])

        store.select(ids[1])
        #expect(store.completedSessionIDs == [ids[3]])
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
        store.sessions[3].onCompletionChange?(true)
        store.select(ids[3])
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func completionSurvivesReorderingAndHiddenTabs() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        for _ in 0..<3 { store.add() }
        let first = store.sessions[0]
        let fourth = store.sessions[3]
        store.select(first.id)
        fourth.onCompletionChange?(true)
        let visible = CodexTabBar.visibleRange(count: store.sessions.count, selectedIndex: 0)
        #expect(!visible.contains(3))
        #expect(store.completedSessionIDs == [fourth.id])

        store.move(fourth.id, before: first.id)
        #expect(store.sessions[0].id == fourth.id)
        #expect(store.completedSessionIDs == [fourth.id])
        store.select(fourth.id)
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func resetAndRestartClearOnlyTheirOwnCompletion() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let first = store.sessions[0]
        let second = store.sessions[1]
        first.onCompletionChange?(true)
        second.onCompletionChange?(true)
        first.onCompletionChange?(false)
        #expect(store.completedSessionIDs == [second.id])
        second.reset()
        #expect(store.completedSessionIDs.isEmpty)
    }

    @Test func removedTabsCannotRestoreTheirBadge() throws {
        let container = try makeContainer()
        let store = CodexTabsStore(context: container.mainContext)
        store.add()
        let removed = store.sessions[1]
        removed.onCompletionChange?(true)
        store.remove(removed.id)
        #expect(store.completedSessionIDs.isEmpty)
        removed.onCompletionChange?(true)
        #expect(store.completedSessionIDs.isEmpty)
    }
}

@Suite @MainActor
struct CodexImageTests {
    private func image() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 {
            for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) }
        }
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        return image
    }

    @Test func pasteAcceptsPNGAndTIFFAndKeepsTextPasting() throws {
        let image = try image()
        let attachment = try #require(CodexImageAttachment(image: image))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = CodexTextView(frame: .zero)
        view.isRichText = false
        var pasted: [NSImage] = []
        view.pasteImages = { pasted += $0 }

        pasteboard.setData(attachment.pngData, forType: .png)
        #expect(view.readablePasteboardTypes.first == .png)
        #expect(view.readSelection(from: pasteboard, type: .png))
        #expect(pasted.count == 1)
        pasteboard.clearContents()
        pasteboard.setData(try #require(image.tiffRepresentation), forType: .tiff)
        #expect(view.readSelection(from: pasteboard, type: .tiff))
        #expect(pasted.count == 2)

        pasteboard.clearContents()
        pasteboard.setString("貼り付けテキスト", forType: .string)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string == "貼り付けテキスト")
        #expect(pasted.count == 2)
    }

    @Test func attachmentsAreIsolatedRemovableAndSentAsPNG() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tabs = CodexTabsStore(context: container.mainContext)
        tabs.add()
        let first = tabs.sessions[0], second = tabs.sessions[1]
        first.addImages([try image()])
        #expect(first.canSend)
        #expect(!second.canSend)
        #expect(second.draftImages.isEmpty)
        let attachment = try #require(first.draftImages.first)
        #expect(attachment.input["type"] == "image")
        let url = try #require(attachment.input["url"])
        #expect(url.hasPrefix("data:image/png;base64,"))
        let data = try #require(Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count))))
        #expect(data == attachment.pngData)
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 2)

        first.draftImages.removeAll { $0.id == attachment.id }
        #expect(!first.canSend)
        first.addImages([try image()])
        first.reset()
        #expect(first.draftImages.isEmpty)
    }

    @Test func notebookGroupsTextAndImagesInOneBox() throws {
        let images = try (0..<2).map { _ in try #require(CodexImageAttachment(image: image())) }
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 800, height: 450))
        let turn = CodexTurn(prompt: "何が写ってる？", images: images)
        book.update([turn])
        let fragments = book.pages.flatMap(\.fragments).filter(\.isUser)
        #expect(fragments.count == 1)
        let fragment = try #require(fragments.first)
        #expect(String(fragment.block.text.characters) == turn.prompt)
        #expect(fragment.images.map(\.id) == images.map(\.id))
        #expect(fragment.height <= book.contentHeight)

        let earlier = CodexTurn(prompt: "前の投稿", images: images, status: "completed")
        book.update([earlier, turn])
        let moved = book.pages.flatMap(\.fragments).filter { $0.isUser && $0.turnID == turn.id }
        #expect(moved.count == 1)
        #expect(moved.first?.images.map(\.id) == images.map(\.id))
        #expect(!book.pages[0].fragments.contains { $0.turnID == turn.id })
    }

    @Test func notebookKeepsImagesAcrossPagesAndResponseUpdates() throws {
        let images = try (0..<3).map { _ in try #require(CodexImageAttachment(image: image())) }
        for prompt in ["", String(repeating: "画像を確認してください。", count: 100)] {
            let book = CodexBookPagination()
            book.configure(viewport: CGSize(width: 600, height: 320))
            var turn = CodexTurn(prompt: prompt, images: images)
            book.update([turn])
            let fragments = book.pages.flatMap(\.fragments)
            #expect(fragments.flatMap { $0.images.map(\.id) } == images.map(\.id))
            #expect(book.pages.count > 1)
            if prompt.isEmpty {
                #expect(fragments.filter { $0.isUser }.allSatisfy { !$0.images.isEmpty })
            }
            for page in book.pages {
                #expect(page.usedHeight <= book.contentHeight + 1)
                for pair in zip(page.fragments, page.fragments.dropFirst()) {
                    #expect(pair.0.y + pair.0.height <= pair.1.y)
                }
            }
            turn.items = [CodexItem(id: "answer", type: "agentMessage", phase: "final_answer",
                                   title: "", text: "確認しました", status: "completed")]
            turn.status = "completed"
            book.update([turn])
            book.update([turn, CodexTurn(prompt: "次の質問")])
            #expect(book.pages.flatMap(\.fragments).flatMap { $0.images.map(\.id) } == images.map(\.id))
        }
    }

    @Test func invalidImageDoesNotBecomeAnAttachment() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        store.addImages([NSImage()])
        #expect(store.draftImages.isEmpty)
        #expect(store.errorMessage != nil)
    }
}
