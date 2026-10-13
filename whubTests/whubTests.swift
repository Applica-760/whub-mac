//
//  whubTests.swift
//  whubTests
//
//  Created by 村上匠 on 2026/10/08.
//

import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite @MainActor
struct CodexResumeTests {
    @Test func resumeInputRequiresTheWholeCommand() {
        #expect(CodexInputView.isResumeInput("/resume"))
        #expect(CodexInputView.isResumeInput(" /resume \n"))
        #expect(!CodexInputView.isResumeInput("/res"))
        #expect(!CodexInputView.isResumeInput("説明 /resume"))
        #expect(!CodexInputView.isResumeInput("/resume 続き"))
        #expect(CodexCommand.allCases.contains(.resume))
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func response(_ turns: [[String: Any]]) -> [String: Any] {
        ["thread": ["id": "thread-1", "turns": turns], "cwd": "/original/project", "model": "saved-model"]
    }

    @Test func recentThreadUsesTitleThenPreviewAndRejectsMissingDirectory() throws {
        var data: [String: Any] = ["id": "thread-1", "cwd": "/project", "updatedAt": 123.0,
                                   "name": "  タイトル  ", "preview": "冒頭文"]
        #expect(try CodexRecentThread(data).displayTitle == "タイトル")
        data["name"] = NSNull()
        #expect(try CodexRecentThread(data).displayTitle == "冒頭文")
        #expect(try CodexRecentThread(data).updatedAt == Date(timeIntervalSince1970: 123))
        data["preview"] = "  "
        #expect(try CodexRecentThread(data).displayTitle == "thread-1")
        data.removeValue(forKey: "cwd")
        #expect(throws: CodexError.self) { try CodexRecentThread(data) }
    }

    @Test func restoresHistoryDirectoryAndLegacyFinalAnswer() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let originalDirectory = store.directory
        let items: [[String: Any]] = [
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "質問"]]],
            ["id": "progress", "type": "agentMessage", "phase": "commentary", "text": "確認中"],
            ["id": "cmd", "type": "commandExecution", "command": "pwd", "aggregatedOutput": "/project", "status": "completed"],
            ["id": "answer", "type": "agentMessage", "text": "回答"]
        ]
        try store.restoreHistory(response([["id": "turn-1", "status": "completed", "items": items]]), expectedID: "thread-1")
        #expect(store.threadID == "thread-1")
        #expect(store.directory == "/original/project")
        #expect(store.model == "saved-model")
        let turn = try #require(store.turns.first)
        #expect(turn.remoteID == "turn-1")
        #expect(turn.displayPrompt == "質問")
        #expect(turn.answers.map(\.text) == ["回答"])
        #expect(turn.history.map(\.id) == ["progress", "cmd"])
        #expect(!store.isBusy)
        store.reset()
        #expect(store.threadID == nil)
        #expect(store.directory == originalDirectory)
    }

    @Test func incompleteHistoryDoesNotPartiallyReplaceState() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let directory = store.directory
        let complete: [String: Any] = ["id": "a", "status": "completed", "items": [[String: Any]]()]
        let invalidTurns: [[String: Any]] = [
            ["id": "b", "status": "inProgress", "items": [[String: Any]]()],
            ["id": "b", "status": "completed", "itemsView": "summary", "items": [[String: Any]]()],
            ["id": "b", "status": "completed"]
        ]
        for invalid in invalidTurns {
            #expect(throws: CodexError.self) {
                try store.restoreHistory(response([complete, invalid]), expectedID: "thread-1")
            }
            #expect(store.turns.isEmpty)
            #expect(store.threadID == nil)
            #expect(store.directory == directory)
        }
        #expect(throws: CodexError.self) { try store.restoreHistory(response([]), expectedID: "wrong-id") }
    }

    @Test func attachmentsRemainVisibleAndCommentaryIsNotAnAnswer() throws {
        let container = try makeContainer()
        let store = CodexStore(context: container.mainContext)
        let items: [[String: Any]] = [
            ["id": "u", "type": "userMessage", "content": [["type": "image", "url": "https://example.invalid/image"]]],
            ["id": "p", "type": "agentMessage", "phase": "commentary", "text": "途中"]
        ]
        try store.restoreHistory(response([["id": "turn-1", "status": "interrupted", "items": items]]), expectedID: "thread-1")
        #expect(store.turns.first?.input == [.attachment(type: "image", name: nil)])
        #expect(store.turns.first?.displayPrompt == "［添付: image］")
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 800, height: 450))
        book.update(store.turns)
        #expect(book.pages.flatMap(\.fragments).contains {
            $0.isUser && String($0.block.text.characters) == "［添付: image］"
        })
        let mixedInput: [[String: Any]] = [
            ["type": "text", "text": "質問"],
            ["type": "skill", "name": "review"],
            ["type": "mention"],
            ["type": "image", "name": "ignored"],
            [:]
        ]
        let mixed = try CodexThreadHistory(response([["id": "mixed", "status": "completed", "items": [
            ["id": "u", "type": "userMessage", "content": mixedInput]
        ]]]), expectedID: "thread-1")
        #expect(mixed.turns.first?.input == [.text("質問"), .attachment(type: "skill", name: "review"),
            .attachment(type: "mention", name: nil), .attachment(type: "image", name: "ignored"),
            .attachment(type: nil, name: nil)])
        #expect(mixed.turns.first?.displayPrompt == "質問\nreview\n添付参照\n［添付: image］\n［添付: 不明］")
        #expect(store.turns.first?.answers.isEmpty == true)
        #expect(store.turns.first?.status == "interrupted")
        #expect(throws: CodexError.self) { try store.restoreHistory(response([]), expectedID: "thread-1") }
        #expect(store.turns.count == 1)
    }

    @Test func resumedTabKeepsOriginalDraftAndParticipatesInNotifications() throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        let original = tabs.selectedSession
        original.draft = "編集中の入力"
        let resumed = CodexStore(context: container.mainContext)
        try resumed.restoreHistory(response([]), expectedID: "thread-1")
        #expect(tabs.openResumedSession(resumed))
        #expect(tabs.sessions.map(\.id) == [original.id, resumed.id])
        #expect(tabs.selectedSessionID == resumed.id)
        #expect(original.draft == "編集中の入力")
        resumed.onCompletionChange?(true)
        #expect(tabs.completedSessionIDs == [resumed.id])
        tabs.remove(resumed.id)
        #expect(tabs.selectedSessionID == original.id)
        #expect(tabs.completedSessionIDs.isEmpty)
    }

    @Test func alreadyOpenThreadIsSelectedWithoutCreatingAnotherTab() async throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        let original = tabs.selectedSession
        try original.restoreHistory(response([]), expectedID: "thread-1")
        tabs.add()
        original.onCompletionChange?(true)
        let thread = try CodexRecentThread(["id": "thread-1", "cwd": "/not-needed", "updatedAt": 1.0])
        #expect(await tabs.resume(thread))
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selectedSessionID == original.id)
        #expect(tabs.completedSessionIDs.isEmpty)
        let duplicate = CodexStore(context: container.mainContext)
        try duplicate.restoreHistory(response([]), expectedID: "thread-1")
        #expect(tabs.openResumedSession(duplicate))
        #expect(tabs.sessions.count == 2)
        #expect(tabs.selectedSessionID == original.id)
    }

    @Test func failedResumeLeavesTabsAndInputUntouched() async throws {
        let container = try makeContainer()
        let tabs = CodexTabsStore(context: container.mainContext)
        let original = tabs.selectedSession
        original.draft = "入力を保持"
        let thread = try CodexRecentThread(["id": "missing", "cwd": "/nonexistent-" + UUID().uuidString, "updatedAt": 1.0])
        #expect(await tabs.resume(thread) == false)
        #expect(tabs.sessions.map(\.id) == [original.id])
        #expect(tabs.selectedSessionID == original.id)
        #expect(original.draft == "入力を保持")
        #expect(tabs.resumeError?.contains("作業フォルダが存在しません") == true)
        #expect(!tabs.isResuming)
        #expect(!tabs.openResumedSession(CodexStore(context: container.mainContext)))
        #expect(tabs.sessions.count == 1)
    }
}

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
        #expect(String(fragment.block.text.characters) == turn.displayPrompt)
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
    @Test func approvalArrivalAndResolutionKeepPagesAndReadingPosition() throws {
        let book = CodexBookPagination()
        book.configure(viewport: CGSize(width: 800, height: 650))
        var turn = CodexTurn(prompt: String(repeating: "本文を読み続ける。\n\n", count: 100))
        book.update([turn])
        #expect(book.spreadCount > 2)
        book.move(1)
        let pages = book.pages.map(\.usedHeight)
        let blocks = book.pages.map { $0.fragments.map(\.block) }
        let spread = book.spread
        for (index, method) in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                                "item/permissions/requestApproval"].enumerated() {
            turn.approvals.append(CodexRequest(rpcID: index, method: method,
                params: ["command": String(repeating: "echo long-command\n", count: 100)]))
            book.update([turn])
            #expect(book.pages.map(\.usedHeight) == pages)
            #expect(book.pages.map { $0.fragments.map(\.block) } == blocks)
            #expect(book.spread == spread)
        }
        for index in turn.approvals.indices {
            turn.approvals[index].outcome = index.isMultiple(of: 2) ? "承認済み" : "拒否済み"
            book.update([turn])
            #expect(book.pages.map(\.usedHeight) == pages)
            #expect(book.spread == spread)
        }
        turn.status = "completed"
        book.update([turn])
        #expect(book.pages.map(\.usedHeight) == pages)
        #expect(book.spread == spread)
        #expect(turn.approvals.count == 3)
    }

    @Test func approvalHeightFitsShortContentAndCapsLongDetails() {
        let short = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
            params: ["command": "pwd", "cwd": "/Users/test", "reason": "確認"])
        let long = CodexRequest(rpcID: 2, method: short.method,
            params: ["command": String(repeating: "echo long-command\n", count: 100),
                     "cwd": "/Users/test", "reason": "確認"])
        for request in [short, long] {
            for expanded in [false, true] {
                let view = NSHostingView(rootView:
                    CodexInteractionRequestView(request: request, detailsExpanded: expanded) { _ in }
                        .frame(width: 320)
                        .frame(maxHeight: 440))
                view.frame.size = view.fittingSize
                view.layoutSubtreeIfNeeded()
                #expect(view.fittingSize.width <= 320)
                #expect(view.fittingSize.height <= 440)
                if request.id == short.id, !expanded {
                    #expect(view.fittingSize.height < 250)
                }
            }
        }
    }

    @Test func keysIgnoreCompositionRepeatsAndUnrelatedKeys() {
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 76, isRepeat: false, hasMarkedText: false) == true)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 53, isRepeat: false, hasMarkedText: false) == false)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: true, hasMarkedText: false) == nil)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 36, isRepeat: false, hasMarkedText: true) == nil)
        #expect(CodexApprovalKeys.approvalDecision(keyCode: 123, isRepeat: false, hasMarkedText: false) == nil)
    }

    @Test func approvalButtonsRespondToNativeKeyEquivalents() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        var decisions: [Bool] = []
        let request = CodexRequest(rpcID: 1, method: "item/commandExecution/requestApproval",
                                   params: ["command": "pwd"])
        let view = NSHostingView(rootView:
            CodexInteractionRequestView(request: request, approvalDecision: { decisions.append($0) }) { _ in }
                .frame(width: 320, height: 240))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            #expect(window.performKeyEquivalent(with: event))
        }
        #expect(decisions == [true, false])
    }

    @Test func approvalKeyViewActivatesItsPopoverWindow() throws {
        final class Window: NSWindow {
            var requestedKey = false
            override func makeKey() { requestedKey = true }
        }
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let view = CodexApprovalKeys.EventView(frame: content.bounds)
        content.addSubview(view)
        #expect(window.requestedKey)
        window.requestedKey = false
        view.removeFromSuperview()
        #expect(!window.requestedKey)
    }

    @Test func popoverKeysOnlyDecideInTheirOwnWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                             styleMask: [.titled], backing: .buffered, defer: false)
        var decisions: [Bool] = []
        let keys = CodexApprovalKeys { decisions.append($0) }
        func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeats: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: repeats, keyCode: code))
        }
        #expect(!keys.handle(try event(36), in: other))
        for modifiers in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            #expect(!keys.handle(try event(36, modifiers: modifiers), in: window))
            #expect(!keys.handle(try event(53, modifiers: modifiers), in: window))
        }
        for code: UInt16 in [4, 37, 44, 123, 124] {
            #expect(!keys.handle(try event(code), in: window))
        }
        #expect(decisions.isEmpty)
        #expect(keys.handle(try event(36), in: window))
        #expect(keys.handle(try event(76, modifiers: [.numericPad, .function]), in: window))
        #expect(keys.handle(try event(53), in: window))
        #expect(keys.handle(try event(36, repeats: true), in: window))
        #expect(keys.handle(try event(53, repeats: true), in: window))
        #expect(decisions == [true, true, false])
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(text)
        #expect(window.makeFirstResponder(text))
        text.setMarkedText("変換中", selectedRange: NSRange(location: 0, length: 3),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.hasMarkedText())
        #expect(!keys.handle(try event(36), in: window))
        #expect(!keys.handle(try event(53), in: window))
        #expect(decisions == [true, true, false])
    }

    @Test func pendingRequestsResolveIndependentlyAndIgnoreDuplicateResponses() throws {
        let container = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CodexStore(context: container.mainContext)
        var sounds: [String] = []
        store.onNotification = { sounds.append($0) }
        for id in [1, 1, 2] {
            store.receive("item/commandExecution/requestApproval", params: [:], requestID: id)
        }
        #expect(store.requests.count == 2)
        #expect(sounds == ["Blow", "Blow"])
        let notificationDate = store.notificationDate
        #expect(notificationDate != nil)
        let first = try #require(store.requests.first)
        store.receive("serverRequest/resolved", params: ["requestId": 1], requestID: nil)
        #expect(store.requests.map(\.id) == ["2"])
        #expect(sounds == ["Blow", "Blow"])
        #expect(store.notificationDate == notificationDate)
        store.approve(first, allow: true)
        #expect(store.errorMessage == nil)
        #expect(store.requests.count == 1)
        store.approve(try #require(store.requests.first), allow: false)
        #expect(store.errorMessage != nil)
        #expect(store.requests.map(\.id) == ["2"])
    }
}

private struct RetainedInputProbe: NSViewRepresentable {
    let created: (NSTextView) -> Void
    func makeNSView(context: Context) -> NSTextView {
        let input = NSTextView()
        created(input)
        return input
    }
    func updateNSView(_ view: NSTextView, context: Context) {}
}

@Suite @MainActor
struct CodexReadingTests {
    @Test func sessionViewsSurviveSwitchesAndClosedTabsAreRemoved() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try #require(window.contentView)
        let coordinator = RetainedPageContainer<Int, RetainedInputProbe>.Coordinator()
        var inputs: [Int: NSTextView] = [:]
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in
            AnyView(RetainedInputProbe { inputs[id] = $0 })
        }
        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        let first = try #require(coordinator.pages[1])
        first.view.layoutSubtreeIfNeeded()
        let input = try #require(inputs[1])
        input.string = "draft"
        input.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(window.makeFirstResponder(input))

        coordinator.update(container, selection: 2, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(first.view.isHidden)
        #expect(!first.activity.isActive.value)
        #expect(window.firstResponder !== input)
        let second = try #require(coordinator.pages[2])
        #expect(second.activity.isActive.value)

        coordinator.update(container, selection: 1, availablePages: [1, 2], isActive: true, rootView: root)
        #expect(coordinator.pages[1]?.view === first.view)
        #expect(coordinator.pages[2]?.view === second.view)
        #expect(!first.view.isHidden)
        #expect(first.activity.isActive.value)
        #expect(!second.activity.isActive.value)
        first.view.layoutSubtreeIfNeeded()
        #expect(inputs[1] === input)
        #expect(input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))

        coordinator.update(container, selection: 1, availablePages: [1], isActive: true, rootView: root)
        #expect(coordinator.pages.count == 1)
        #expect(second.view.superview == nil)
        #expect(!second.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === first.view)
    }

    @Test func hiddenFeatureDeactivatesItsRetainedSession() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = RetainedPageContainer<Int, Text>.Coordinator()
        let root: (Int, RetainedPageActivity) -> AnyView = { id, _ in AnyView(Text("Session \(id)")) }
        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)
        let session = try #require(coordinator.pages[1])
        coordinator.update(container, selection: 1, availablePages: nil, isActive: false, rootView: root)
        #expect(!session.activity.isActive.value)
        coordinator.update(container, selection: 1, availablePages: nil, isActive: true, rootView: root)
        #expect(session.activity.isActive.value)
        #expect(coordinator.pages[1]?.view === session.view)
    }

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
        let keys = CodexPageKeys(focus: focus, move: { moves.append($0) })
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
