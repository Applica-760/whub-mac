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
        var continued = false

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

struct CodexMarkdownBlockView: View {
    typealias Block = CodexMarkdown.Block
    let block: Block
    var ordered = false
    let width: CGFloat
    @Environment(\.codexSelectionOrder) private var selectionOrder
    @Environment(\.codexSelectionSource) private var selectionSource

    private var contents: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(block.children.enumerated()), id: \.element.id) { index, child in
                CodexMarkdownBlockView(block: child, width: width - (block.kind == .blockQuote ? 14 : 32))
                    .environment(\.codexSelectionOrder, selectionOrder + [index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        rendered.environment(\.codexSelectionSource, selectionSource + ":" + String(block.id))
    }

    @ViewBuilder private var rendered: some View {
        switch block.kind {
        case .thematicBreak:
            Divider().padding(.vertical, 6)
        case .header(let level):
            CodexMathText(text: block.text, fontSize: [25.0, 22, 20, 18, 16, 15][min(max(level, 1), 6) - 1], weight: .regular)
                .font(.system(size: [25.0, 22, 20, 18, 16, 15][min(max(level, 1), 6) - 1],
                              weight: .regular))
                .foregroundStyle(level == 6 ? Color.secondary : Color.primary)
                .padding(.top, level <= 2 ? 10 : 4)
                .padding(.bottom, level <= 2 ? 4 : 0)
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(block.children.enumerated()), id: \.element.id) { index, child in
                    CodexMarkdownBlockView(block: child, ordered: block.kind == .orderedList, width: width)
                        .environment(\.codexSelectionOrder, selectionOrder + [index])
                }
            }
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ordered ? "\(ordinal)." : "•")
                    .font(.system(size: 15, weight: .light).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
                    .opacity(block.continued ? 0 : 1)
                contents
            }
        case .blockQuote:
            contents
                .padding(.leading, 14)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3)
                }
        case .codeBlock:
            ScrollView(.horizontal) {
                CodexMathText(text: AttributedString(String(block.text.characters)), fontSize: 14, weight: .regular, lineSpacing: 0, monospaced: true)
                    .padding(12)
            }
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    // shortcut: copies the page fragment; retain source text if whole-block copying is needed.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(12)
                .background(CodexSelectionExclusion())
            }
        case .table(let columns):
            TableView(block: block, columns: columns, width: width)
        default:
            if block.children.isEmpty {
                CodexMathText(text: block.text)
                    .font(.system(size: 15, weight: .light))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                contents
            }
        }
    }
}

private struct TableView: View {
    let block: CodexMarkdown.Block
    let columns: [PresentationIntent.TableColumn]
    let width: CGFloat
    @Environment(\.codexSelectionSource) private var selectionSource
    @Environment(\.codexSelectionOrder) private var selectionOrder

    private var columnWidth: CGFloat {
        max(120, min(300, width / CGFloat(max(columns.count, 1))))
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(block.children.enumerated()), id: \.element.id) { rowIndex, row in
                    GridRow {
                        ForEach(columns.indices, id: \.self) { index in
                            let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                            CodexMathText(text: cell?.text ?? AttributedString(),
                                          weight: row.kind == .tableHeaderRow ? .regular : .light,
                                          alignment: columns[index].alignment == .right ? .right : columns[index].alignment == .center ? .center : .left, lineSpacing: 0)
                                .environment(\.codexSelectionOrder, selectionOrder + [rowIndex, index])
                                .environment(\.codexSelectionSource, selectionSource + ":" + String(cell?.id ?? -index - 1))
                                .font(.system(size: 15, weight: row.kind == .tableHeaderRow ? .regular : .light))
                                .multilineTextAlignment(columns[index].alignment == .right ? .trailing
                                    : columns[index].alignment == .center ? .center : .leading)
                                .frame(width: columnWidth - 24, alignment: columns[index].alignment == .right ? .trailing
                                    : columns[index].alignment == .center ? .center : .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(row.kind == .tableHeaderRow ? Color.secondary.opacity(0.12) : .clear, in: Rectangle())
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }
}

/// AppKit rendering shares the parser and math renderer with the existing SwiftUI view.
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
                let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                let lines = code.components(separatedBy: "\n")
                let lineHeight = ceil(font.ascender - font.descender + font.leading)
                let size = CGSize(width: max(1, width - indent), height: CGFloat(max(1, lines.count)) * lineHeight + 24)
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
