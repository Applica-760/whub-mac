// テスト一覧:
// - numberShortcutsSwitchInputAndRetainAgentSessions(): [TAB-F-001] [TAB-F-005] [TAB-F-006]
// - commandWConfirmsCloseAndFocusesRemainingAgentTab(): [TAB-F-007] [TAB-F-011]
// - tailUpdateDoesNotLayOutUnchangedFrontPages(): 末尾更新で変更のない前方ページを再配置しない。
// - incrementalLayoutMatchesFreshLayoutAcrossEditsAndResize(): 差分更新と初回レイアウトの結果が一致する。
// - fixedPromptAreaKeepsAdditionalInputsAndAnswerOnOnePage(): 追加入力と回答を同じページに保持する。
// - imagesAndCodeRemainOrderedAcrossPagesAndAnswerUpdates(): 画像とコードの順序を更新後も保持する。
// - textReplacementKeepsReadingFocusAndSelection(): 本文更新で閲覧フォーカスと選択を保持する。
// - shrinkingPagesDoesNotStealInputFocus(): ページ縮小時に入力フォーカスを奪わない。
// - copyingSelectionRestoresCodeAndFormulaSources(): 選択範囲のコピーでコードと数式の元テキストを復元する。
// - nativeInputAcceptsPNGAndTIFFAndSendsTypedDraft(): 画像貼付けと入力した下書きの送信。
// - inputGrowthKeepsBookSize(): Input growth retains the Book viewport and space for bottom controls.
// - inputScrollsAfterFifteenDisplayLines(): Input height is capped while long drafts remain scrollable.
// - completionTokenRequiresCommandPositionAndHandlesUnicode(): 補完トークンの位置判定とUnicode対応。
// - approvalKeysRespectIMERepeatsWindowAndBookActivity(): 承認キーのIME・リピート・Window・アクティブ状態判定。
// - readingKeysMovePagesAndReturnToDraftWithoutConsumingEditorKeys(): 閲覧キーのページ移動と入力への復帰。

import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import WhubAgent
@testable import whub

@Suite(.serialized) @MainActor
struct AgentBookViewTests {
    @Test func textLinkUsesAgentBookHandler() throws {
        let surface = AgentBookTextSurface(book: AgentBookPageLayout())
        let text = NSTextView()
        let url = try #require(URL(string: "https://example.com"))
        var opened: URL?
        surface.openLink = { opened = $0; return true }
        #expect(surface.textView(text, clickedOnLink: url, at: 0))
        #expect(opened == url)
        #expect(!surface.textView(text, clickedOnLink: 42, at: 0))
    }

    @Test func linkFilePathsUseSessionDirectory() throws {
        let path = WorkspaceView<EmptyView>.filePath
        #expect(path(try #require(URL(string: "src/main.swift:12:3")), "/work/project") == "/work/project/src/main.swift")
        #expect(path(try #require(URL(string: "../other.swift#L4")), "/work/project") == "/work/other.swift")
        #expect(path(try #require(URL(string: "file:///work/My%20File.swift:5")), nil) == "/work/My File.swift")
        #expect(path(try #require(URL(string: "/work/file.swift:9")), nil) == "/work/file.swift")
        #expect(path(try #require(URL(string: "relative.swift")), nil) == nil)
        #expect(path(try #require(URL(string: "mailto:test@example.com")), "/work") == nil)
    }

    @Test func numberShortcutsSwitchInputAndRetainAgentSessions() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var backends: [TestAgentSession] = []
        let book = AgentBookStore(context: database.mainContext, runtime: AgentRuntime(makeAdapter: { _ in
            let adapter = TestAgentSession()
            backends.append(adapter)
            return adapter
        }), notify: { _ in })
        defer { book.disconnect() }
        for _ in 1..<9 { book.add() }
        let tabs = book.tabs
        for (index, tab) in tabs.enumerated() { tab.store.draft = [.text("Seed \(index)")] }
        let connections = RemoteConnectionStore()
        let servers = RemoteServerStore(connections: connections)
        var targetsAgentBook = false
        let host = NSHostingView(rootView: VStack {
            AgentBookTabMenu(store: book, isActive: true, isShortcutTarget: { targetsAgentBook })
            AgentBookView(store: book).environmentObject(connections).environmentObject(servers)
        })
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is NSTextView && tabs[8].store.isConnected
        }
        let inactiveNumberKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        _ = host.performKeyEquivalent(with: inactiveNumberKey)
        #expect(book.selectedTab === tabs[8])
        targetsAgentBook = true
        var inputs: [NSTextView] = []

        for (index, keyCode) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            let key = String(index + 1)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(keyCode)))
            #expect(host.performKeyEquivalent(with: event))
            try await waitForEditorTest {
                host.layoutSubtreeIfNeeded()
                return book.selectedTab === tabs[index] && tabs[index].store.isConnected
                    && (window.firstResponder as? NSTextView)?.string == "Seed \(index)"
            }
            let input = try #require(window.firstResponder as? NSTextView)
            inputs.append(input)
            input.insertText("Draft \(index)", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
            try await waitForEditorTest { tabs[index].store.draft.agentBookDraftText == "Draft \(index)" }
        }
        book.select(tabs[0].id)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder === inputs[0]
        }
        #expect(inputs[0].string == "Draft 0")
        #expect(book.selectedTab === tabs[0])
        #expect(backends.count == 9)
        #expect(backends.allSatisfy { $0.directories.count == 1 && !$0.isClosed })
        #expect(zip(book.tabs, tabs).allSatisfy { $0 === $1 })
    }

    @Test(arguments: [1, 2])
    func commandWConfirmsCloseAndFocusesRemainingAgentTab(tabCount: Int) async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let book = AgentBookStore(context: database.mainContext,
            runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { book.disconnect() }
        let first = book.selectedTab
        first.store.draft = [.text("keep")]
        if tabCount == 2 { book.add() }
        let closing = book.selectedTab
        let connections = RemoteConnectionStore()
        let servers = RemoteServerStore(connections: connections)
        let host = NSHostingView(rootView: AgentBookView(store: book)
            .environmentObject(connections).environmentObject(servers))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is NSTextView && closing.store.isConnected
        }

        try sendTabTestKey("w", code: 13, to: window)
        try await waitForEditorTest { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        let confirm = try #require(tabTestViews(in: content, of: NSButton.self).first { $0.title == "タブを閉じる" })
        confirm.performClick(nil)

        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return book.selectedTabID != closing.id && window.attachedSheet == nil
                && window.firstResponder is NSTextView
        }
        #expect(book.tabs.count == 1 && closing.store.isClosed)
        let input = try #require(window.firstResponder as? NSTextView)
        if tabCount == 1 {
            #expect(book.selectedTab !== closing)
            #expect(book.selectedTab.store.exchanges.isEmpty && book.selectedTab.store.draft.isEmpty)
            #expect(input.string.isEmpty)
        } else {
            #expect(book.selectedTab === first && input.string == "keep")
        }
        input.insertText("x", replacementRange: NSRange(location: input.string.utf16.count, length: 0))
        try await waitForEditorTest { book.selectedTab.store.draft.agentBookDraftText == (tabCount == 1 ? "x" : "keepx") }
    }

    @Test func tailUpdateDoesNotLayOutUnchangedFrontPages() throws {
        let book = AgentBookPageLayout()
        let probe = AgentBookLayoutProbe()
        var exchanges = (0..<8).map { testExchange("Question \($0)", answer: String(repeating: "Paragraph \($0).\n\n", count: 12)) }
        let viewport = CGSize(width: 800, height: 450)
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .light)
        let first = try #require(book.pages.first)
        for page in book.pages { page.manager.delegate = probe }
        exchanges[7].outputs = testExchange(answer: "Updated final answer").outputs
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .light)
        #expect(!probe.laidOutContainers.isEmpty)
        #expect(!probe.laidOutContainers.contains { $0 === first.container })
        #expect(book.pages.first === first)
        let fresh = AgentBookPageLayout()
        fresh.update(exchanges, agentName: "Codex")
        fresh.prepare(viewport: viewport, colorScheme: .light)
        #expect(book.pages.map { $0.storage.string } == fresh.pages.map { $0.storage.string })
    }

    @Test func incrementalLayoutMatchesFreshLayoutAcrossEditsAndResize() throws {
        let book = AgentBookPageLayout()
        var exchanges = (0..<8).map { testExchange("Question \($0)", answer: String(repeating: "Paragraph \($0). 日本語の本文。\n\n", count: 12)) }
        var viewport = CGSize(width: 800, height: 450)
        var scheme = ColorScheme.light
        book.update(exchanges, agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: scheme)
        let originalPages = book.pages
        #expect(originalPages.count == exchanges.count)
        for edit in 0..<6 {
            switch edit {
            case 0: exchanges[7].outputs = testExchange(answer: "Appended answer.\n\n```swift\nlet value = 1\n```").outputs
            case 1: exchanges[4].outputs = testExchange(answer: "Shortened middle answer").outputs
            case 2: exchanges.removeLast(3)
            case 3: exchanges.removeAll()
            case 4:
                exchanges = [testExchange("New conversation")]
                viewport = CGSize(width: 600, height: 320)
            default: scheme = .dark
            }
            book.update(exchanges, agentName: "Codex")
            #expect(book.prepare(viewport: viewport, colorScheme: scheme))
            let fresh = AgentBookPageLayout()
            fresh.update(exchanges, agentName: "Codex")
            fresh.prepare(viewport: viewport, colorScheme: scheme)
            #expect(book.pages.count == exchanges.count)
            #expect(book.pages.map { $0.storage.string } == fresh.pages.map { $0.storage.string })
            #expect(book.pages.flatMap(\.codes).map(\.text) == fresh.pages.flatMap(\.codes).map(\.text))
            #expect(book.headers.map(\.frame) == fresh.headers.map(\.frame))
            #expect(!book.prepare(viewport: viewport, colorScheme: scheme))
            if edit == 0 { #expect(zip(book.pages.prefix(3), originalPages.prefix(3)).allSatisfy { $0 === $1 }) }
        }
    }

    @Test func fixedPromptAreaKeepsAdditionalInputsAndAnswerOnOnePage() throws {
        let prompt = (1...80).map { "error line \($0)" }.joined(separator: "\n")
        var exchange = testExchange(prompt, answer: "before additional")
        exchange.additionalInputs = [whub.AgentAdditionalInput(input: [.text("additional prompt")], outputIndex: 1)]
        exchange.outputs += [.message(whub.AgentMessage(id: "second", role: .answer, title: "Answer", content: .text("after additional"), status: .completed))]
        let book = AgentBookPageLayout()
        let viewport = CGSize(width: 800, height: 450)
        book.update([exchange], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 1)
        let page = try #require(book.pages.first)
        let input = try #require(page.prompts.first)
        #expect(page.prompts.count == 1)
        #expect(input.text.string.contains(prompt))
        #expect(input.text.string.contains("additional prompt"))
        #expect(input.size.height == book.pageSize.height * 0.15)
        #expect((input.text.string as NSString).range(of: prompt).location < (input.text.string as NSString).range(of: "additional prompt").location)
        #expect((page.storage.string as NSString).range(of: "before additional").location < (page.storage.string as NSString).range(of: "after additional").location)
        let short = AgentBookPageLayout()
        short.update([testExchange("short")], agentName: "Codex")
        short.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.headers.first?.frame.minY == short.headers.first?.frame.minY)
        exchange.outputs[1] = .message(whub.AgentMessage(id: "second", role: .answer, title: "Answer", content: .text("updated"), status: .completed))
        book.update([exchange], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 1 && page.storage.string.contains("updated"))
        book.update([exchange, testExchange("Next input")], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.count == 2)
        #expect(book.selectedPage == 1)
        #expect(book.pages[1].prompts.first?.text.string.contains("Next input") == true)
        book.selectPage(0)
        #expect(book.selectedPage == 0 && book.spread == 0)
        exchange.outputs = testExchange(answer: "Further answer update").outputs
        book.update([exchange, testExchange("Next input")], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.selectedPage == 0)
        book.selectPage(1)
        #expect(book.selectedPage == 1 && book.spread == 1)
        let third = testExchange("Third input")
        book.update([exchange, testExchange("Next input"), third], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.selectedPage == 2)
        book.move(-1)
        #expect(book.selectedPage == 1 && book.spread == 1)
        book.move(1)
        #expect(book.selectedPage == 2 && book.spread == 2)
        book.move(1)
        #expect(book.selectedPage == 2)
        book.update([], agentName: "Codex")
        book.prepare(viewport: viewport, colorScheme: .dark)
        #expect(book.pages.isEmpty)
    }

    @Test func imagesAndCodeRemainOrderedAcrossPagesAndAnswerUpdates() throws {
        let images = try (0..<3).map { _ in whub.AgentImageAttachment(image: try testImage()) }
        var exchange = testExchange("What is shown?", answer: String(repeating: "paragraph\n\n", count: 30) + "```swift\n" + String(repeating: "let value = 1\n", count: 50) + "```")
        exchange.input += images.map(whub.AgentInput.image)
        let book = AgentBookPageLayout()
        for scheme in [ColorScheme.light, .dark] {
            book.update([exchange], agentName: "Codex")
            book.prepare(viewport: CGSize(width: 800, height: 450), colorScheme: scheme)
            var found: [NSImage] = []
            let page = try #require(book.pages.first)
            let prompt = try #require(page.prompts.first)
            prompt.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: prompt.text.length)) { value, _, _ in
                if let image = (value as? NSTextAttachment)?.image { found.append(image) }
            }
            #expect(found.count == images.count)
            #expect(zip(found, images).allSatisfy { $0.0 === $0.1.image })
            #expect(page.codes.map(\.text).joined() == String(repeating: "let value = 1\n", count: 50))
            #expect(book.pages.count == 1)
        }
    }

    @Test func textReplacementKeepsReadingFocusAndSelection() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let book = AgentBookPageLayout()
        var exchange = testExchange("first page", answer: "")
        book.update([exchange], agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame = content.bounds
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let focus = AgentBookFocus()
        focus.readingView = surface
        focus.activateReading()
        #expect(window.firstResponder === surface)
        let textViews = surface.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
        let text = try #require(textViews.first)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        exchange.outputs = testExchange(answer: "appended answer").outputs
        book.update([exchange], agentName: "Codex")
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(focus.isReading(in: window) && text.selectedRange() == NSRange(location: 0, length: 5))
        #expect(book.pages.first?.storage.string.contains("appended answer") == true)
    }

    @Test func shrinkingPagesDoesNotStealInputFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        let focus = AgentBookFocus()
        let book = AgentBookPageLayout()
        let exchanges = (0..<3).map { _ in testExchange(String(repeating: "長い本文。\n\n", count: 100)) }
        book.update(exchanges, agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame = content.bounds
        focus.readingView = surface
        content.addSubview(surface)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let originalPages = surface.subviews.compactMap { $0 as? NSScrollView }
        try #require(originalPages.count == 1)
        let input = NSTextView(frame: content.bounds)
        input.string = "draft"
        content.addSubview(input)
        focus.inputView = input
        input.setSelectedRange(NSRange(location: 2, length: 0))
        focus.activateInput()
        book.update([testExchange("short")], agentName: "Codex")
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        #expect(surface.subviews.compactMap { $0 as? NSScrollView }.count == 1)
        #expect(originalPages.allSatisfy { $0.superview == nil })
        #expect(window.firstResponder === input && input.string == "draft")
        #expect(input.selectedRange() == NSRange(location: 2, length: 0))
        surface.isHidden = true
        focus.activateReading()
        #expect(window.firstResponder === input)
    }

    @Test func copyingSelectionRestoresCodeAndFormulaSources() throws {
        let book = AgentBookPageLayout()
        let source = "Inline $x^2$\n\n```swift\nlet x = 1\n```"
        book.update([testExchange("Question", answer: source)], agentName: "Codex")
        let surface = AgentBookTextSurface(book: book)
        surface.frame.size = CGSize(width: 800, height: 450)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        let textViews = surface.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }
        let text = try #require(textViews.first)
        text.setSelectedRange(NSRange(location: 0, length: try #require(book.pages.first).storage.length))
        let pasteboard = NSPasteboard.withUniqueName()
        #expect(text.writeSelection(to: pasteboard, type: .string))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied.contains("$x^2$") && copied.contains("let x = 1"))
        #expect(!copied.contains("\u{FFFC}"))
    }

    @Test func nativeInputAcceptsPNGAndTIFFAndSendsTypedDraft() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        let focus = AgentBookFocus()
        let root = AgentBookInputView(store: store, skillStore: AgentSkillStore(agent: store),
            historyStore: AgentHistoryStore(agent: store), focus: focus, agentName: "Codex",
            newConversation: {}, resume: { _ in false }).frame(width: 600, height: 160)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(await testEventually { focus.inputView != nil })
        let input = try #require(focus.inputView as? NSTextView)
        let image = try testImage()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        for (type, bytes) in [(NSPasteboard.PasteboardType.png, png), (.tiff, tiff)] {
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.setData(bytes, forType: type)
            #expect(input.readSelection(from: pasteboard, type: type))
        }
        #expect(store.draft.agentBookImages.count == 2)
        store.draft.insert(.text("describe"), at: 0)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        input.keyDown(with: event)
        #expect(await testEventually { backend.sent.count == 1 })
        #expect(backend.sent.first?.filter { if case .image = $0 { return true }; return false }.count == 2)
        #expect(backend.sent.first?.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() == "describe")
        #expect(store.draft.isEmpty)
    }

    @Test func inputGrowthKeepsBookSize() async throws {
        let database = try ModelContainer(for: Host.self, LocalHost.self, RemoteHost.self, Project.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let book = AgentBookStore(context: database.mainContext,
            runtime: AgentRuntime(makeAdapter: { _ in TestAgentSession() }), notify: { _ in })
        defer { book.disconnect() }
        let connections = RemoteConnectionStore()
        let servers = RemoteServerStore(connections: connections)
        let host = NSHostingView(rootView: AgentBookView(store: book)
            .environmentObject(connections).environmentObject(servers))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return window.firstResponder is NSTextView && book.selectedTab.store.isConnected
        }
        let input = try #require(window.firstResponder as? NSTextView)
        let scroll = try #require(input.enclosingScrollView)
        #expect(scroll.frame.width > 500)
        func bookSurface(in view: NSView) -> AgentBookTextSurface? {
            if let surface = view as? AgentBookTextSurface { return surface }
            return view.subviews.lazy.compactMap { bookSurface(in: $0) }.first
        }
        let surface = try #require(bookSurface(in: host))
        let bookSize = surface.bounds.size
        #expect(scroll.convert(scroll.bounds, to: nil).minY >= 44)
        input.insertText(Array(repeating: "long error", count: 80).joined(separator: "\n"),
                         replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return scroll.contentSize.height > 150 && input.frame.height > scroll.contentSize.height * 2
        }
        #expect(scroll.convert(scroll.bounds, to: nil).minY >= 44)
        #expect(surface.bounds.size == bookSize)
        #expect(scroll.frame.width > 500)
        #expect(scroll.convert(scroll.bounds, to: nil).maxY < 430)
    }

    @Test func inputScrollsAfterFifteenDisplayLines() async throws {
        let store = AgentStore(kind: .codex, target: testAgentTarget(TestAgentSession()))
        defer { store.disconnect() }
        store.draft = [.text(Array(repeating: "error line", count: 15).joined(separator: "\n"))]
        let focus = AgentBookFocus()
        let host = NSHostingView(rootView: VStack {
            Spacer()
            AgentBookInputView(store: store, skillStore: AgentSkillStore(agent: store),
                historyStore: AgentHistoryStore(agent: store), focus: focus, agentName: "Codex",
                newConversation: {}, resume: { _ in false })
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return focus.inputView?.enclosingScrollView?.contentSize.height ?? 0 > 100
        }
        let input = try #require(focus.inputView as? NSTextView)
        let scroll = try #require(input.enclosingScrollView)
        let font = try #require(input.font)
        let lineHeight = try #require(input.layoutManager).defaultLineHeight(for: font)
        let maximumHeight = ceil(lineHeight * 15)
        #expect(abs(scroll.contentSize.height - maximumHeight) <= 1)
        let longDraft = Array(repeating: "error line", count: 80).joined(separator: "\n")
        input.insertText(longDraft, replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return input.frame.height > maximumHeight * 4
        }
        #expect(abs(scroll.contentSize.height - maximumHeight) <= 1)
        #expect(store.draft.agentBookDraftText == longDraft)
        input.scrollRangeToVisible(NSRange(location: input.string.utf16.count, length: 0))
        #expect(scroll.contentView.bounds.minY > 0)
        #expect(scroll.documentVisibleRect.maxY >= input.bounds.maxY - lineHeight)

        store.draft = [.text(String(repeating: "long error message ", count: 200))]
        window.setContentSize(NSSize(width: 400, height: 550))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return input.string == store.draft.agentBookDraftText && input.frame.height > maximumHeight * 2
        }
        #expect(scroll.contentSize.height <= maximumHeight + 1)
        #expect(focus.inputView === input)

        store.draft = [.text("short")]
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return input.string == "short" && scroll.contentSize.height < lineHeight * 2
        }
        #expect(scroll.contentView.bounds.minY == 0)

        window.setContentSize(NSSize(width: 1400, height: 550))
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return scroll.frame.width > 700
        }
        #expect(scroll.frame.width < 868)
    }

    @Test func completionTokenRequiresCommandPositionAndHandlesUnicode() {
        #expect(AgentBookInputToken.at(NSRange(location: 4, length: 0), in: "/res")?.text == "/res")
        #expect(AgentBookInputToken.at(NSRange(location: 8, length: 0), in: "text /re") == nil)
        let source = "日本語 $review"
        let end = (source as NSString).length
        #expect(AgentBookInputToken.at(NSRange(location: end, length: 0), in: source)?.text == "$review")
        #expect(AgentBookInputToken.at(NSRange(location: end, length: 1), in: source) == nil)
        #expect(AgentBookInputToken.at(NSRange(location: end + 1, length: 0), in: source) == nil)
    }

    @Test func approvalKeysRespectIMERepeatsWindowAndBookActivity() async throws {
        let window = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let other = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let sessionActivity = RetainedPageActivity()
        let featureActivity = RetainedPageActivity()
        sessionActivity.setActive(true)
        featureActivity.setActive(true)
        let request = try CodexMapping.request(method: "item/commandExecution/requestApproval", params: ["command": "ls"], rpcID: 1)
        var decisions: [Bool] = []
        let host = NSHostingView(rootView: AgentBookApprovalEntryView(request: request, pageSize: CGSize(width: 700, height: 500),
            contentBottom: 60, scale: 1, sessionActivity: sessionActivity, featureActivity: featureActivity) { _, allow in decisions.append(allow) })
        let content = try #require(window.contentView)
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        NSApplication.shared.sendEvent(try testKey(window, code: 36))
        #expect(decisions == [true])
        NSApplication.shared.sendEvent(try testKey(window, code: 36, isRepeat: true))
        NSApplication.shared.sendEvent(try testKey(window, code: 36, modifiers: .command))
        NSApplication.shared.sendEvent(try testKey(other, code: 36))
        #expect(decisions == [true])
        let composing = AgentBookComposingText(frame: .zero)
        content.addSubview(composing)
        window.makeFirstResponder(composing)
        NSApplication.shared.sendEvent(try testKey(window, code: 36))
        #expect(decisions == [true])
        window.makeFirstResponder(nil)
        sessionActivity.isActive.value = false
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true])
        sessionActivity.isActive.value = true
        featureActivity.isActive.value = false
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true])
        featureActivity.isActive.value = true
        NSApplication.shared.sendEvent(try testKey(window, code: 53))
        #expect(decisions == [true, false])
    }

    @Test func readingKeysMovePagesAndReturnToDraftWithoutConsumingEditorKeys() async throws {
        let backend = TestAgentSession()
        let store = AgentStore(kind: .codex, target: testAgentTarget(backend))
        defer { store.disconnect() }
        await store.connect(directory: "/project")
        for index in 0..<3 {
            await store.send([.text("question \(index)")])
            backend.emit(.output(.message(WhubAgent.AgentMessage(id: "a", role: .answer, title: "Answer",
                content: .markdown(String(repeating: "Answer \(index).\n\n", count: 100)), status: .completed))))
            backend.emit(.completed)
            #expect(await testEventually { !store.isBusy })
        }
        let focus = AgentBookFocus()
        var spread = 0
        var pageCount = 0
        let window = AgentBookTestKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AgentBookExchangeView(store: store, agentName: "Codex",
            spread: Binding(get: { spread }, set: { spread = $0 }), pageCountChanged: { pageCount = $0 }, focus: focus))
        let content = try #require(window.contentView)
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        #expect(await testEventually { focus.readingView != nil && pageCount > 2 })
        let input = NSTextView(frame: .zero)
        input.string = "draft"
        input.setSelectedRange(NSRange(location: 2, length: 0))
        content.addSubview(input)
        focus.inputView = input
        focus.activateReading()
        #expect(focus.isReading(in: window))
        let initial = spread
        try #require(initial > 0)
        NSApplication.shared.sendEvent(try testKey(window, code: 4, characters: "h"))
        #expect(await testEventually { spread == initial - 1 })
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l"))
        #expect(await testEventually { spread == initial })
        NSApplication.shared.sendEvent(try testKey(window, code: 4, characters: "h"))
        #expect(await testEventually { spread == initial - 1 })
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l", modifiers: .command))
        #expect(spread == initial - 1)
        let surface = try #require(focus.readingView as? AgentBookTextSurface)
        let visiblePages = surface.subviews.compactMap { $0 as? NSScrollView }
            .filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
        let page = try #require(visiblePages.first)
        try #require(visiblePages.count == 1)
        let originalY = page.contentView.bounds.minY
        NSApplication.shared.sendEvent(try testKey(window, code: 38, characters: "j"))
        #expect(page.contentView.bounds.minY > originalY)
        NSApplication.shared.sendEvent(try testKey(window, code: 40, characters: "k"))
        #expect(abs(page.contentView.bounds.minY - originalY) < 1)
        NSApplication.shared.sendEvent(try testKey(window, code: 49, characters: " "))
        #expect(window.firstResponder === input)
        NSApplication.shared.sendEvent(try testKey(window, code: 40, characters: "k", isRepeat: true))
        #expect(input.string == "draft")
        #expect(input.string == "draft" && input.selectedRange() == NSRange(location: 2, length: 0))
        NSApplication.shared.sendEvent(try testKey(window, code: 37, characters: "l"))
        #expect(spread == initial - 1)
    }
}

private final class AgentBookLayoutProbe: NSObject, NSLayoutManagerDelegate {
    var laidOutContainers: [NSTextContainer] = []

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        laidOutContainers.append(textContainer)
        return false
    }
}

@MainActor
private func testKey(_ window: NSWindow, code: UInt16, characters: String = "\r",
                     modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code))
}

private final class AgentBookTestKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private final class AgentBookComposingText: NSTextView {
    override func hasMarkedText() -> Bool { true }
}
