// テスト一覧:
// - inlineCodeAndFormulaRenderWithinParagraph(): [MD-F-003] [MD-F-004]
// - markdownRendersTableAndCodeBlock(): [MD-F-001] [MD-F-002]

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import whub

@Suite @MainActor
struct MarkdownDocumentTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func inlineCodeAndFormulaRenderWithinParagraph(colorScheme: ColorScheme) async throws {
        let host = NSHostingView(rootView: MarkdownView(source: "Before `let value = 1` and $x^2$ after")
            .environment(\.colorScheme, colorScheme))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)

        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return textView(in: host)?.string == "Before let value = 1 and \u{FFFC} after\n"
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
        let formulaRange = (storage.string as NSString).range(of: "\u{FFFC}")
        try #require(formulaRange.location != NSNotFound)
        let attachment = try #require(storage.attribute(.attachment, at: formulaRange.location, effectiveRange: nil) as? NSTextAttachment)
        let image = try #require(attachment.image)
        #expect(image.size.width > 0 && image.size.height > 0)
        let formulaGlyphs = manager.glyphRange(forCharacterRange: formulaRange, actualCharacterRange: nil)
        let formulaBounds = manager.boundingRect(forGlyphRange: formulaGlyphs, in: container)
        #expect(formulaBounds.width > 0 && formulaBounds.height > 0)
        #expect(formulaBounds.minX > bounds.maxX)
        #expect(formulaBounds.intersects(NSRect(x: formulaBounds.minX, y: bounds.minY, width: formulaBounds.width, height: bounds.height)))
        withExtendedLifetime(host) {}
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func markdownRendersTableAndCodeBlock(colorScheme: ColorScheme) async throws {
        let source = """
        # Heading

        | Fruit | Color |
        | --- | --- |
        | Apple | Red |
        | Banana | Yellow |

        ```swift
        let x = 1
        ```
        """
        let blocks = MarkdownSource(source: source).blocks
        try #require(blocks.count == 3)
        #expect(blocks.first?.kind == .header(level: 1))
        if case .table(let columns) = blocks[1].kind {
            #expect(columns.count == 2)
            #expect(blocks[1].children.count == 3)
        } else {
            Issue.record("Markdown table was not preserved")
        }
        #expect(blocks.last?.kind == .codeBlock(languageHint: "swift"))
        let cells = [["Fruit", "Color"], ["Apple", "Red"], ["Banana", "Yellow"]]
        let host = NSHostingView(rootView: MarkdownView(source: source)
            .environment(\.colorScheme, colorScheme))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let expectedText = "Heading\n" + cells.flatMap { $0 }.joined(separator: "\n") + "\n\u{FFFC}\n"

        try await waitForEditorTest {
            host.layoutSubtreeIfNeeded()
            return textViews(in: host).count == 2
        }

        let text = try #require(textView(in: host))
        let manager = try #require(text.layoutManager)
        let container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        let rows = try cells.map { row in
            try row.map { cell in
                let range = (text.string as NSString).range(of: cell)
                try #require(range.location != NSNotFound)
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
                #expect(bounds.width > 0 && bounds.height > 0)
                return bounds
            }
        }
        for row in rows {
            #expect(abs(row[0].minY - row[1].minY) < 1)
            #expect(row[0].maxX < row[1].minX)
        }
        for index in 1..<rows.count {
            for column in 0..<2 {
                #expect(abs(rows[index][column].minX - rows[0][column].minX) < 1)
                #expect(rows[index - 1][column].maxY < rows[index][column].minY)
            }
        }
        #expect(text.string == expectedText)
        let code = try #require(textViews(in: host).first { $0 !== text })
        #expect(code.string == "let x = 1\n")
        #expect(!code.isHiddenOrHasHiddenAncestor)
        let codeBounds = code.convert(code.bounds, to: text)
        #expect(codeBounds.width > 0 && codeBounds.height > 0)
        let lastRowBottom = try #require(rows.last?.map(\.maxY).max()) + text.textContainerOrigin.y
        #expect(codeBounds.minY > lastRowBottom)
        withExtendedLifetime(host) {}
    }

    private func textView(in view: NSView) -> NSTextView? {
        textViews(in: view).first
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        let current = (view as? NSTextView).map { [$0] } ?? []
        return current + view.subviews.flatMap { textViews(in: $0) }
    }
}
