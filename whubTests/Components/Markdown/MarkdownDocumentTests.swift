// テスト一覧:
// - markdownParserPreservesStructuredBlocks(): [MD-F-001] [MD-F-002]
// - inlineCodeIsVisuallyDistinctWithinRenderedParagraph(): [MD-F-003]

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import whub

@Suite @MainActor
struct MarkdownDocumentTests {
    @Test func markdownParserPreservesStructuredBlocks() throws {
        let source = """
        # Heading

        | A | B |
        | --- | --- |
        | one | two |

        ```swift
        let x = 1
        ```

        """

        let blocks = MarkdownSource(source: source).blocks

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

    @Test(arguments: [ColorScheme.light, .dark])
    func inlineCodeIsVisuallyDistinctWithinRenderedParagraph(colorScheme: ColorScheme) async throws {
        let host = NSHostingView(rootView: MarkdownView(source: "Before `let value = 1` after")
            .environment(\.colorScheme, colorScheme))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return textView(in: host)?.string == "Before let value = 1 after\n"
        }

        let text = try #require(textView(in: host))
        let storage = try #require(text.textStorage)
        let codeRange = (storage.string as NSString).range(of: "let value = 1")
        let beforeFont = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let afterIndex = NSMaxRange(codeRange)
        let afterFont = try #require(storage.attribute(.font, at: afterIndex, effectiveRange: nil) as? NSFont)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.backgroundColor, at: afterIndex, effectiveRange: nil) == nil)
        storage.enumerateAttributes(in: codeRange) { attributes, _, _ in
            #expect((attributes[.font] as? NSFont).map { $0 != beforeFont && $0 != afterFont } == true)
            #expect((attributes[.backgroundColor] as? NSColor).map { $0.alphaComponent > 0 } == true)
        }
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: codeRange, actualCharacterRange: nil)
        let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
        #expect(bounds.width > 0 && bounds.height > 0)
        withExtendedLifetime(host) {}
    }
}
