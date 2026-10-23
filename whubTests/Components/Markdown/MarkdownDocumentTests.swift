// テスト一覧:
// - markdownParserPreservesStructuredBlocks(): [MD-F-001] [MD-F-002] 表・コードブロックの解析構造を検証する（部分対応。描画は未検証）。要求IDのない見出しの構造と、各ブロックの順序も確認する。

import Foundation
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
}
