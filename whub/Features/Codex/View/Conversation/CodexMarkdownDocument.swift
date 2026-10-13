import AppKit
import SwiftUI

/// Keep Markdown containers so nested lists and multi-paragraph quotes stay together.
struct CodexMarkdown {
    let source: String

    struct Block: Identifiable, Hashable {
        let id: Int
        let kind: PresentationIntent.Kind
        var text = AttributedString()
        var children: [Block] = []

        mutating func append(_ text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>) {
            guard let component = path.first else {
                self.text.append(text)
                return
            }
            if children.last?.id != component.identity {
                children.append(Block(id: component.identity, kind: component.kind))
            }
            children[children.count - 1].append(text, path: path.dropFirst())
        }
    }

    var blocks: [Block] {
        let math = CodexMathSource(source)
        guard let markdown = try? AttributedString(markdown: math.markdown, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        let parsed = math.restoringFormulas(in: markdown)
        var root = Block(id: -1, kind: .paragraph)
        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .system(size: 14, design: .monospaced)
                text.backgroundColor = Color.secondary.opacity(0.16)
            }
            if path.isEmpty {
                root.children.append(Block(id: -(root.children.count + 2), kind: .paragraph, text: text))
            } else {
                root.append(text, path: path[...])
            }
        }
        return root.children
    }

}

struct CodexMarkdownDocument {
    let text: NSAttributedString
    let codes: [Code]

    struct Code {
        let range: NSRange
        let text: String
        let size: CGSize
    }

    init(source: String, width: CGFloat, colorScheme: ColorScheme) {
        let output = NSMutableAttributedString(string: "")
        var codes: [Code] = []
        var afterTable = false
        let renderer = CodexMathRenderer(weight: .regular, colorScheme: colorScheme)
        var separator = NSColor.separatorColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            separator = NSColor.separatorColor.usingColorSpace(.deviceRGB) ?? .separatorColor
        }

        func paragraph(_ text: NSAttributedString, indent: CGFloat = 0,
                       blocks: [NSTextBlock] = [], before: CGFloat = 0) {
            let part = NSMutableAttributedString(attributedString: text)
            part.append(NSAttributedString(string: "\n"))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = 10
            style.paragraphSpacingBefore = afterTable ? 12 : before
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.textBlocks = blocks
            part.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: part.length))
            output.append(part)
            afterTable = false
        }

        func render(_ block: CodexMarkdown.Block, indent: CGFloat = 0,
                    ordered: Bool = false, decorations: [NSTextBlock] = []) {
            switch block.kind {
            case .orderedList, .unorderedList:
                for child in block.children {
                    render(child, indent: indent, ordered: block.kind == .orderedList, decorations: decorations)
                }
            case .listItem(let ordinal):
                for (index, child) in block.children.enumerated() {
                    if index == 0, child.children.isEmpty {
                        let part = NSMutableAttributedString(attributedString: renderer.attributed(AttributedString(ordered ? "\(ordinal).  " : "•  ")))
                        part.append(renderer.attributed(child.text))
                        paragraph(part, indent: indent + 16, blocks: decorations)
                    } else { render(child, indent: indent + 24, decorations: decorations) }
                }
            case .blockQuote:
                let quote = NSTextBlock()
                quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                quote.setBorderColor(NSColor.secondaryLabelColor.withAlphaComponent(0.5))
                quote.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                for child in block.children { render(child, indent: indent, decorations: decorations + [quote]) }
            case .header(let level):
                let size = [25.0, 22, 20, 18, 16, 15][min(max(level, 1), 6) - 1]
                paragraph(CodexMathRenderer(fontSize: size, weight: .regular, colorScheme: colorScheme).attributed(block.text),
                          indent: indent, blocks: decorations, before: level <= 2 ? 10 : 4)
            case .codeBlock:
                let code = String(block.text.characters)
                let lines = code.components(separatedBy: "\n")
                let lineHeight = CodexBookLayout.codeLineHeight
                let size = CGSize(width: max(1, width - indent), height: CGFloat(max(1, lines.count)) * lineHeight + 2 * CodexBookLayout.codeInset)
                let attachment = NSTextAttachment()
                attachment.bounds = CGRect(origin: .zero, size: size)
                let part = NSMutableAttributedString(attachment: attachment)
                part.addAttribute(.codexBookCodeSource, value: code, range: NSRange(location: 0, length: 1))
                codes.append(Code(range: NSRange(location: output.length, length: 1), text: code, size: size))
                paragraph(part, indent: indent, blocks: decorations)
            case .table(let columns):
                guard !columns.isEmpty else { return }
                let table = NSTextTable()
                table.numberOfColumns = columns.count
                table.collapsesBorders = true
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                let rows = block.children.map { row in
                    columns.indices.map { index in
                        let text = row.children.first { $0.kind == .tableCell(columnIndex: index) }?.text ?? AttributedString()
                        return renderer.attributed(text)
                    }
                }
                let preferred = columns.indices.map { column in
                    ceil(rows.map { $0[column].size().width }.max() ?? 0) + 2
                }
                let padding = CGFloat(columns.count) * 24
                let natural = preferred.reduce(0, +)
                let tableWidth = min(natural + padding, max(1, width - indent))
                table.setContentWidth(tableWidth, type: .absoluteValueType)
                for (rowIndex, row) in rows.enumerated() {
                    for column in columns.indices {
                        let cell = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                    startingColumn: column, columnSpan: 1)
                        cell.setContentWidth(max(1, tableWidth - padding) * preferred[column] / max(1, natural), type: .absoluteValueType)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                        cell.setBorderColor(separator)
                        cell.setWidth(6, type: .absoluteValueType, for: .padding)
                        cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                        cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                        if block.children[rowIndex].kind == .tableHeaderRow {
                            cell.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
                        }
                        let start = output.length
                        paragraph(row[column], indent: indent, blocks: decorations + [cell])
                        let style = (output.attribute(.paragraphStyle, at: start, effectiveRange: nil) as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                        style.lineSpacing = 0
                        style.paragraphSpacing = 0
                        style.alignment = columns[column].alignment == .right ? .right : columns[column].alignment == .center ? .center : .left
                        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
                    }
                }
                afterTable = true
            case .thematicBreak:
                let rule = NSTextBlock()
                rule.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(separator)
                paragraph(NSAttributedString(string: ""), indent: indent, blocks: decorations + [rule])
            default:
                if block.children.isEmpty {
                    paragraph(renderer.attributed(block.text), indent: indent, blocks: decorations)
                } else {
                    for child in block.children { render(child, indent: indent, decorations: decorations) }
                }
            }
        }
        for block in CodexMarkdown(source: source).blocks { render(block) }
        assert(codes.allSatisfy {
            output.attribute(.codexBookCodeSource, at: $0.range.location, effectiveRange: nil) as? String == $0.text
        }, "Code attachments must retain their complete, unwrapped source for copying")
        text = output
        self.codes = codes
    }
}

extension NSAttributedString.Key {
    static let codexBookCodeSource = NSAttributedString.Key("whub.book.codeSource")
}
