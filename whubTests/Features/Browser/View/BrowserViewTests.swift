// テスト一覧:
// - numberKeysSelectBrowserTabsInDisplayOrder(): [TAB-F-001]
// - switchingBrowserTabsRestoresFocusScrollAndPageState(): [TAB-F-004] [TAB-F-006]
// - browserConsumesOnlyUnhandledPlainArrowsFromVisibleWebContent(): 可視Webコンテンツが未処理の矢印キーだけを消費する。
// - browserFocusesVisibleWebContentWithoutClicking(): 可視Webコンテンツへのフォーカス移動と非表示時の拒否。
// - browserScrollsWithJKExceptWhenEditing(): 編集・IME・修飾キーと入れ子のスクロール領域を検証する。
// - browserLoadsLocalHTMLAndRelativeResources(): ローカルHTMLと相対リソースを読み込む。
// - commandWClosesSelectedBrowserTabAndReplacesLast(): [TAB-F-007] [TAB-F-009]

import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
import WebKit
import WhubCore
@testable import whub

@Suite @MainActor
struct BrowserViewTests {
    @Test func numberKeysSelectBrowserTabsInDisplayOrder() async throws {
        let store = BrowserStore()
        for _ in 1..<9 { store.add() }
        let sessions = store.sessions
        for (index, session) in sessions.enumerated() { session.address = "Draft \(index)" }
        let defaultsName = "BrowserNumberTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(BookmarkStorage.initialData, forKey: BookmarkStorage.key)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let host = NSHostingView(rootView: BrowserView().environmentObject(store).defaultAppStorage(defaults))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return tabTestViews(in: host, of: NSTextField.self).contains { $0.isEditable }
        }
        let address = try #require(tabTestViews(in: host, of: NSTextField.self).first { $0.isEditable })
        #expect(window.makeFirstResponder(address))

        for (index, keyCode) in [18, 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            try sendTabTestKey(String(index + 1), code: UInt16(keyCode), to: window)
            try await waitForEditorTest {
                host.layoutSubtreeIfNeeded()
                return store.selectedSession === sessions[index]
            }
            #expect(store.selectedSession.address == "Draft \(index)")
        }
        store.move(sessions[8].id, before: sessions[0].id)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try sendTabTestKey("1", code: 18, to: window)
        #expect(store.selectedSession === sessions[8])
        #expect(store.sessions.count == 9)
    }

    @Test func switchingBrowserTabsRestoresFocusScrollAndPageState() async throws {
        let store = BrowserStore()
        store.add()
        let sessions = store.sessions
        for (index, session) in sessions.enumerated() {
            session.showsBookmarks = false
            session.page.load(html: "<title>Tab \(index)</title><style>body { height: 5000px; }</style><input id='draft'>")
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while sessions.contains(where: { $0.page.isLoading || $0.page.title.isEmpty }) {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        let host = NSHostingView(rootView: BrowserView().environmentObject(store))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        var pages: [WKWebView] = []
        for index in [1, 0] {
            if index == 0 { try sendTabTestKey("1", code: 18, to: window) }
            try await waitForEditorTest {
                host.layoutSubtreeIfNeeded()
                return tabTestViews(in: host, of: WKWebView.self).contains {
                    !$0.isHiddenOrHasHiddenAncestor && (window.firstResponder as? NSView)?.isDescendant(of: $0) == true
                }
            }
            let page = try #require(tabTestViews(in: host, of: WKWebView.self).first { !$0.isHiddenOrHasHiddenAncestor })
            pages.append(page)
        }
        _ = try await sessions[0].page.callJavaScript("window.keptToken = 'retained'; document.getElementById('draft').value = 'unsaved'; window.scrollTo(0, 240)")
        try sendTabTestKey("2", code: 19, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSView)?.isDescendant(of: pages[0]) == true
        }
        try sendTabTestKey("1", code: 18, to: window)
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return (window.firstResponder as? NSView)?.isDescendant(of: pages[1]) == true
        }
        #expect(store.selectedSession === sessions[0])
        #expect(try await sessions[0].page.callJavaScript("return window.keptToken") as? String == "retained")
        #expect(try await sessions[0].page.callJavaScript("return document.getElementById('draft').value") as? String == "unsaved")
        #expect(try await sessions[0].page.callJavaScript("return window.scrollY") as? Int == 240)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        window.firstResponder?.keyDown(with: down)
        let scrollDeadline = ContinuousClock.now + .seconds(3)
        while try await sessions[0].page.callJavaScript("return window.scrollY") as? Int != 360 {
            guard ContinuousClock.now < scrollDeadline else {
                Issue.record("J scroll: \(String(describing: try await sessions[0].page.callJavaScript("return window.scrollY")))")
                throw SSHError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        window.firstResponder?.keyDown(with: up)
        let upDeadline = ContinuousClock.now + .seconds(3)
        while try await sessions[0].page.callJavaScript("return window.scrollY") as? Int != 240 {
            guard ContinuousClock.now < upDeadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func browserConsumesOnlyUnhandledPlainArrowsFromVisibleWebContent() throws {
        final class KeyReceiver: NSResponder {
            var count = 0
            override func keyDown(with event: NSEvent) { count += 1 }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = BrowserContainerView(frame: window.contentView!.bounds)
        window.contentView = container
        let webView = WKWebView(frame: container.bounds)
        container.addSubview(webView)
        #expect(window.makeFirstResponder(webView))
        let receiver = KeyReceiver()
        container.nextResponder = receiver

        func send(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeatKey, keyCode: keyCode))
            container.keyDown(with: event)
        }

        for key in UInt16(123)...126 {
            try send(key)
            try send(key, modifiers: [.function, .numericPad], repeatKey: true)
        }
        #expect(receiver.count == 0)
        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            try send(125, modifiers: modifier)
        }
        try send(0)
        #expect(receiver.count == 5)

        webView.isHidden = true
        try send(125)
        #expect(receiver.count == 6)
        webView.isHidden = false
        let input = NSTextView(frame: container.bounds)
        container.addSubview(input)
        #expect(window.makeFirstResponder(input))
        try send(125)
        #expect(receiver.count == 7)
    }

    @Test func browserFocusesVisibleWebContentWithoutClicking() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = BrowserContainerView(frame: window.contentView!.bounds)
        window.contentView = container
        let page = NSView(frame: container.bounds)
        container.addSubview(page)
        let webView = WKWebView(frame: page.bounds)
        page.addSubview(webView)
        let address = NSTextView(frame: container.bounds)
        container.addSubview(address)
        #expect(window.makeFirstResponder(address))
        #expect(container.focusWebContent(in: page))
        #expect((window.firstResponder as? NSView)?.isDescendant(of: webView) == true)
        #expect(window.makeFirstResponder(address))
        page.isHidden = true
        #expect(!container.focusWebContent(in: page))
        #expect(window.firstResponder === address)
    }

    @Test func browserScrollsWithJKExceptWhenEditing() async throws {
        let page = BrowserStore().selectedSession.page
        page.load(html: """
            <title>Scroll Test</title>
            <style>body { height: 5000px; } #pane { height: 100px; overflow-y: auto; }</style>
            <input id="input"><textarea id="textarea"></textarea><select id="select"><option>A</option></select>
            <div id="editor" contenteditable="true"><span id="nested">Edit</span></div>
            <div id="pane" tabindex="0"><div style="height: 1000px">Scroll</div></div>
            """)
        let deadline = ContinuousClock.now + .seconds(15)
        while page.isLoading || page.title != "Scroll Test" {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await page.callJavaScript("""
            const failures = [];
            function check(condition, name) { if (!condition) failures.push(name); }
            function send(target, key, options = {}) {
                return target.dispatchEvent(new KeyboardEvent('keydown', {
                    key, bubbles: true, cancelable: true, composed: true, ...options
                }));
            }
            window.scrollTo(0, 0);
            check(!send(document.body, 'j') && window.scrollY === 120, 'j down');
            check(!send(document.body, 'j', { repeat: true }) && window.scrollY === 240, 'held j');
            check(!send(document.body, 'k') && window.scrollY === 120, 'k up');
            check(!send(document.body, 'J', { shiftKey: true }) && window.scrollY === 480, 'shift j down');
            check(!send(document.body, 'J', { shiftKey: true, repeat: true }) && window.scrollY === 840, 'held shift j');
            check(!send(document.body, 'K', { shiftKey: true }) && window.scrollY === 480, 'shift k up');
            check(!send(document.body, 'j') && window.scrollY === 600, 'j after shift released');
            check(!send(document.body, 'k') && window.scrollY === 480, 'k after shift released');
            window.scrollTo(0, 120);
            for (const id of ['input', 'textarea', 'select', 'nested']) {
                const element = document.getElementById(id);
                element.focus({ preventScroll: true });
                check(send(element, 'j') && window.scrollY === 120, id);
                check(send(element, 'J', { shiftKey: true }) && window.scrollY === 120, id + ' shift');
            }
            for (const flag of ['isComposing', 'metaKey', 'ctrlKey', 'altKey']) {
                check(send(document.body, 'j', { [flag]: true }) && window.scrollY === 120, flag);
                check(send(document.body, 'J', { shiftKey: true, [flag]: true }) && window.scrollY === 120, flag + ' shift');
            }
            check(send(document.body, 'j', { keyCode: 229 }) && window.scrollY === 120, 'IME keyCode');
            check(send(document.body, 'J', { shiftKey: true, keyCode: 229 }) && window.scrollY === 120, 'IME keyCode shift');
            check(send(document.body, 'x') && window.scrollY === 120, 'other key');
            const pane = document.getElementById('pane');
            check(!send(pane, 'j') && pane.scrollTop === 120 && window.scrollY === 120, 'nested scroll');
            check(!send(pane, 'J', { shiftKey: true }) && pane.scrollTop === 480 && window.scrollY === 120, 'nested shift j');
            check(!send(pane, 'K', { shiftKey: true }) && pane.scrollTop === 120 && window.scrollY === 120, 'nested shift k');
            return failures;
            """)
        #expect(try #require(result as? [String]).isEmpty)
    }

    @Test func browserLoadsLocalHTMLAndRelativeResources() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DerivedData/ExplorerStoreTests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local page.html")
        try Data("<title>Local HTML</title><link rel='stylesheet' href='style.css'><body><img src='icon.svg'></body>".utf8).write(to: url)
        try Data("body { color: rgb(1, 2, 3); }".utf8).write(to: directory.appendingPathComponent("style.css"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'></svg>".utf8).write(to: directory.appendingPathComponent("icon.svg"))
        let browser = BrowserStore()
        let firstID = browser.selectedSessionID
        browser.open(url)
        #expect(browser.sessions.count == 2)
        #expect(browser.selectedSessionID != firstID)
        #expect(!browser.selectedSession.showsBookmarks)
        #expect(BrowserStore.url(from: url.absoluteString) == url)
        #expect(BrowserStore.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(BrowserStore.url(from: "javascript://alert(1)") == nil)
        let page = browser.selectedSession.page
        let deadline = ContinuousClock.now + .seconds(15)
        while page.isLoading || page.title != "Local HTML" {
            guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await page.callJavaScript("return getComputedStyle(document.body).color") as? String == "rgb(1, 2, 3)")
        #expect(try await page.callJavaScript("return document.images[0].naturalWidth") as? Int == 12)
        #expect(browser.selectedSession.address == url.absoluteString)
    }
    @Test(arguments: [1, 2])
    func commandWClosesSelectedBrowserTabAndReplacesLast(tabCount: Int) async throws {
        let store = BrowserStore()
        let first = store.selectedSession
        first.address = "retained draft"
        if tabCount == 2 { store.add() }
        let closing = store.selectedSession
        let defaultsName = "BrowserTabTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(BookmarkStorage.initialData, forKey: BookmarkStorage.key)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let host = NSHostingView(rootView: BrowserView().environmentObject(store).defaultAppStorage(defaults))
        let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return tabTestViews(in: host, of: NSTextField.self).contains { $0.isEditable }
        }
        let address = try #require(tabTestViews(in: host, of: NSTextField.self).first { $0.isEditable })
        #expect(window.makeFirstResponder(address))

        try sendTabTestKey("w", code: 13, to: window)

        try #require(store.selectedSessionID != closing.id)
        #expect(store.sessions.count == 1)
        #expect(!store.sessions.contains { $0 === closing })
        if tabCount == 1 {
            #expect(store.selectedSession.page !== closing.page)
            #expect(store.selectedSession.address.isEmpty)
            #expect(store.selectedSession.showsBookmarks)
        } else {
            #expect(store.selectedSession === first)
            #expect(first.address == "retained draft")
        }
        let selected = store.selectedSessionID
        store.remove(closing.id)
        #expect(store.sessions.count == 1 && store.selectedSessionID == selected)
    }
}
