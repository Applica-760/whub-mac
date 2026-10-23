import AppKit
import Combine
import SwiftData
import SwiftUI
import Testing
import WhubCore
@testable import whub

@Suite(.serialized) @MainActor
struct MarkdownDocumentTests {
    @Test func markdownParserPreservesStructuredBlocks() throws {
        let blocks = MarkdownSource(source: "# Heading\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet x = 1\n```\n").blocks
        try #require(blocks.count == 3)
        #expect(blocks.first?.kind == .header(level: 1))
        if case .table(let columns) = blocks[1].kind {
            #expect(columns.count == 2 && blocks[1].children.count == 2)
        } else { Issue.record("Markdown table was not preserved") }
        #expect(blocks.last?.kind == .codeBlock(languageHint: "swift"))
    }
}
