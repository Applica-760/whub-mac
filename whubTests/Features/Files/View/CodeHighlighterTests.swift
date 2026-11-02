import AppKit
import Synchronization
import Testing
import WhubGit
@testable import whub

@Suite @MainActor
struct CodeHighlighterTests {
    @Test func appliesOnlyChangedAttributesAndSkipsIdenticalResults() {
        let text = NSMutableAttributedString(string: String(repeating: "line\n", count: 100), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
        ])
        text.fixAttributes(in: NSRange(location: 0, length: text.length))
        let storage = NSTextStorage(attributedString: text)
        let edits = Mutex<[NSRange]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                let storage = notification.object as! NSTextStorage
                edits.withLock { $0.append(storage.editedRange) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        CodeHighlighter.apply(.init(text: text), to: storage)
        #expect(edits.withLock { $0.isEmpty })
        let changed = NSRange(location: 250, length: 4)
        text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: changed)
        CodeHighlighter.apply(.init(text: text), to: storage)
        #expect(storage.isEqual(to: text))
        #expect(edits.withLock { $0 == [changed] })
        edits.withLock { $0.removeAll() }
        CodeHighlighter.apply(.init(text: text), to: storage)
        #expect(edits.withLock { $0.isEmpty })
    }

    @Test func matchesFullApplicationAcrossSyntaxAndThemeChanges() async throws {
        let highlighter = CodeHighlighter()
        for (language, sources) in [
            ("swift", ["let value = \"日本語😀\"\nlet other = 1\n", "/* let value = \"日本語😀\"\nlet other = 1\n", "/* comment */\nlet other = 1\n"]),
            ("markdown", ["**日本語**\n```swift\nlet value = 1\n```\n", "**日本語**\n```swift\nlet value = 1\n", "日本語 *italic*\n"]),
        ] {
            let storage = NSTextStorage()
            for dark in [false, true, false] {
                for source in sources {
                    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
                    let result = try #require(await highlighter.highlight(.init(source: source, language: language, dark: dark, diffLines: nil)))
                    let full = NSTextStorage(attributedString: storage)
                    full.beginEditing()
                    result.text.enumerateAttributes(in: NSRange(location: 0, length: result.text.length)) { attributes, range, _ in
                        full.setAttributes(attributes, range: range)
                    }
                    full.endEditing()
                    CodeHighlighter.apply(result, to: storage)
                    #expect(storage.isEqual(to: full))
                    #expect(storage.string == source)
                }
            }
        }
        let source = "added\nfolded\n"
        let styled = try #require(await highlighter.highlight(.init(source: source, language: nil, dark: false, diffLines: [
            DiffLine(number: 1, source: "added\n", change: .added),
            DiffLine(number: nil, source: "folded\n", change: nil, foldedRange: 1..<10),
        ])))
        let storage = NSTextStorage(attributedString: styled.text)
        let plain = try #require(await highlighter.highlight(.init(source: source, language: nil, dark: true, diffLines: nil)))
        CodeHighlighter.apply(plain, to: storage)
        #expect(storage.isEqual(to: NSTextStorage(attributedString: plain.text)))
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func coordinatorKeepsLatestTextSelectionAndUndo() async throws {
        let file = FileStore(content: .text("let value = 1\n"), isEditable: true)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        file.textStorage.addLayoutManager(layout)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), textContainer: container)
        view.fileStore = file
        view.isEditable = true
        view.allowsUndo = true
        let scroll = NSScrollView()
        scroll.documentView = view
        file.editorViews.views["test"] = scroll
        let coordinator = CodeEditorView.Coordinator()
        coordinator.observe(file.textStorage)
        func request() -> CodeHighlighter.Request {
            .init(source: file.textStorage.string, language: "swift", dark: false, diffLines: nil)
        }
        coordinator.highlight(request(), state: file, textView: view)
        try await waitForEditorTest { coordinator.highlighted == request() }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.insertText("x", replacementRange: view.selectedRange())
        coordinator.highlight(request(), state: file, textView: view)
        view.insertText("y", replacementRange: view.selectedRange())
        coordinator.highlight(request(), state: file, textView: view)
        let source = file.textStorage.string, selection = view.selectedRange()
        try await waitForEditorTest { coordinator.highlighted == request() }
        #expect(file.textStorage.string == source)
        #expect(view.selectedRange() == selection)
        #expect(file.undoManager.canUndo)
        file.undoManager.undo()
        #expect(file.textStorage.string != source)
        file.undoManager.redo()
        #expect(file.textStorage.string == source)
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
        #expect(view.hasMarkedText())
        let marked = NSAttributedString(attributedString: file.textStorage)
        coordinator.highlight(request(), state: file, textView: view)
        try await Task.sleep(for: .milliseconds(300))
        #expect(file.textStorage.isEqual(to: marked))
        #expect(coordinator.highlighted == nil)
        view.unmarkText()
        coordinator.highlight(request(), state: file, textView: view)
        try await waitForEditorTest { coordinator.highlighted == request() }
        coordinator.cancelHighlight()
    }
}
