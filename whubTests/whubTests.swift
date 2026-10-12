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

@Suite @MainActor
struct CodexApprovalTests {
    @Test func resolvedRequestsKeepBookLayoutIndependentOfDetails() throws {
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 600, height: 320))
        let request = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
                                   params: ["command": "/bin/date"])
        var turn = CodexTurn(prompt: "確認", approvals: [request])
        book.update([turn])
        book.revealApproval(request.id)
        #expect(book.visibleApproval?.id == request.id)
        let expandedHeight = try #require(book.pages.flatMap(\.fragments).first { $0.approval != nil }).height
        turn.approvals[0].outcome = "承認済み"
        turn.status = "completed"
        book.update([turn])
        #expect(book.visibleApproval == nil)
        let collapsedHeight = try #require(book.pages.flatMap(\.fragments).first { $0.approval != nil }).height
        #expect(collapsedHeight < expandedHeight)
        let pageCount = book.pages.count
        let heights = book.pages.map(\.usedHeight)
        book.update([turn], expandedApprovalDetailsIDs: [request.id])
        #expect(book.visibleApproval == nil)
        #expect(book.pages.count == pageCount)
        #expect(book.pages.map(\.usedHeight) == heights)
        #expect(book.pages.flatMap(\.fragments).first { $0.approval != nil }?.height == collapsedHeight)
        for page in book.pages { #expect(page.usedHeight <= book.contentHeight) }
    }

    @Test func approvalHeightFitsContentAndCapsLongDetails() throws {
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 800, height: 650))
        let request = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
                                   params: ["command": "/usr/bin/true", "reason": "確認", "cwd": "/Users/test"])
        let turn = CodexTurn(prompt: "確認", approvals: [request])
        book.update([turn])
        let shortHeight = try #require(book.pages.flatMap(\.fragments).first { $0.approval != nil }).height
        #expect(shortHeight < 250)
        book.update([turn], expandedApprovalDetailsIDs: [request.id])
        let detailHeight = try #require(book.pages.flatMap(\.fragments).first { $0.approval != nil }).height
        #expect(detailHeight > shortHeight)
        let longRequest = CodexRequest(rpcID: 2, method: request.method,
                                       params: ["reason": String(repeating: "長い説明\n", count: 100)])
        book.update([CodexTurn(prompt: "確認", approvals: [longRequest])])
        let longHeight = try #require(book.pages.flatMap(\.fragments).first { $0.approval != nil }).height
        #expect(longHeight == book.contentHeight)
    }

    @Test func keysIgnoreCompositionRepeatsAndUnrelatedKeys() {
        #expect(CodexPageKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexPageKeys.approvalDecision(keyCode: 76, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexPageKeys.approvalDecision(keyCode: 53, isRepeat: false, hasMarkedText: false) == false)
        #expect(CodexPageKeys.approvalDecision(keyCode: 36, isRepeat: true, hasMarkedText: false) == nil)
        #expect(CodexPageKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: true) == nil)
        #expect(CodexPageKeys.approvalDecision(keyCode: 123, isRepeat: false, hasMarkedText: false) == nil)
    }

    @Test func pendingRequestsResolveIndependentlyAndIgnoreDuplicateResponses() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        for id in [1, 1, 2] {
            store.receive("item/commandExecution/requestApproval", params: [:], requestID: id)
        }
        #expect(store.requests.count == 2)
        let first = try #require(store.requests.first)
        store.receive("serverRequest/resolved", params: ["requestId": 1], requestID: nil)
        #expect(store.requests.map(\.id) == ["2"])
        store.approve(first, allow: true)
        #expect(store.errorMessage == nil)
        #expect(store.requests.count == 1)
        store.approve(try #require(store.requests.first), allow: false)
        #expect(store.errorMessage != nil)
        #expect(store.requests.map(\.id) == ["2"])
    }
}

@Suite @MainActor
struct CodexReadingTests {
    @Test func textReplacementKeepsReadingFocusAndSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let selection = CodexBookSelection()
        let focus = CodexBookFocus()
        let surface = CodexBookSurfaceView(frame: content.bounds)
        surface.selection = selection
        selection.surface = surface
        focus.readingView = surface
        content.addSubview(surface)
        let text = CodexSelectableTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        text.isEditable = false
        text.isSelectable = true
        text.string = "first page"
        text.bookSelection = selection
        selection.texts.add(text)
        content.addSubview(text)
        focus.activateReading()
        surface.selectAll(nil)
        #expect(selection.selectedString == "first page")
        #expect(focus.isReading(in: window))
        text.removeFromSuperview()
        selection.remove(text)
        #expect(window.firstResponder === surface)
        #expect(selection.selectedString.isEmpty)

        let replacement = CodexSelectableTextView(frame: text.frame)
        replacement.isEditable = false
        replacement.isSelectable = true
        replacement.string = "next page"
        replacement.bookSelection = selection
        selection.texts.add(replacement)
        content.addSubview(replacement)
        surface.selectAll(nil)
        #expect(selection.selectedString == "next page")
        // Native multi-click selection may temporarily focus an individual text view.
        #expect(window.makeFirstResponder(replacement))
        #expect(focus.isReading(in: window))
        replacement.removeFromSuperview()
        #expect(window.firstResponder === surface)
    }

    @Test func removingTextDoesNotStealInputFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let selection = CodexBookSelection()
        let focus = CodexBookFocus()
        let surface = CodexBookSurfaceView(frame: content.bounds)
        surface.selection = selection
        selection.surface = surface
        focus.readingView = surface
        content.addSubview(surface)
        let text = CodexSelectableTextView(frame: content.bounds)
        text.bookSelection = selection
        content.addSubview(text)
        let input = CodexTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        focus.inputView = input
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.activateInput()
        text.removeFromSuperview()
        #expect(window.firstResponder === input)
        #expect(!focus.isReading(in: window))
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        surface.isHidden = true
        focus.activateReading()
        #expect(window.firstResponder === input)
    }

    @Test func readingShortcutsMoveAndReturnToDraftWithoutConsumingEditorKeys() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let selection = CodexBookSelection()
        let focus = CodexBookFocus()
        let surface = CodexBookSurfaceView(frame: content.bounds)
        surface.selection = selection
        selection.surface = surface
        focus.readingView = surface
        content.addSubview(surface)
        let input = CodexTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.inputView = input
        var moves: [Int] = []
        let keys = CodexPageKeys(focus: focus, paneFocus: TabPaneFocus(), approval: nil,
                                approve: { _, _ in Issue.record("Unexpected approval") }, move: { moves.append($0) })
        func event(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        focus.activateReading()
        for (characters, code) in [("h", UInt16(4)), ("l", 37), ("", 123), ("", 124)] {
            #expect(keys.handle(try event(characters, code: code)))
            #expect(window.firstResponder === surface)
        }
        #expect(moves == [-1, 1, -1, 1])
        #expect(!keys.handle(try event("x", code: 7)))
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!keys.handle(try event("l", code: 37, modifiers: modifiers)))
            #expect(!keys.handle(try event("/", code: 44, modifiers: modifiers)))
        }
        #expect(keys.handle(try event("/", code: 44)))
        #expect(window.firstResponder === input)
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        for (characters, code) in [("h", UInt16(4)), ("l", 37), ("/", 44), ("", 123), ("", 124)] {
            #expect(!keys.handle(try event(characters, code: code)))
        }
        let other = CodexBookSurfaceView(frame: content.bounds)
        content.addSubview(other)
        #expect(window.makeFirstResponder(other))
        #expect(!keys.handle(try event("l", code: 37)))
        #expect(!keys.handle(try event("/", code: 44)))

        let composing = ComposingInputText(frame: content.bounds)
        content.addSubview(composing)
        #expect(window.makeFirstResponder(composing))
        #expect(!keys.handle(try event("l", code: 37)))
        #expect(!keys.handle(try event("/", code: 44)))
        #expect(window.firstResponder === composing)
        #expect(moves == [-1, 1, -1, 1])
    }

    @Test func markdownParserPreservesStructuredBlocks() throws {
        let blocks = CodexMarkdown(source: "# Heading\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet x = 1\n```\n").blocks
        try #require(blocks.count == 3)
        #expect(blocks.first?.kind == .header(level: 1))
        if case .table(let columns) = blocks[1].kind {
            #expect(columns.count == 2)
            #expect(blocks[1].children.count == 2)
        } else {
            Issue.record("Markdown table was not preserved")
        }
        #expect(blocks.last?.kind == .codeBlock(languageHint: "swift"))
    }
}

private final class ComposingInputText: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
