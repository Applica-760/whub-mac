import SwiftUI

/// Keep Markdown containers so nested lists and multi-paragraph quotes stay together.
struct CodexMarkdownResponseView: View {
    let source: String

    private struct Block: Identifiable {
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

    private var blocks: [Block] {
        let math = CodexMathSource(source)
        guard let markdown = try? AttributedString(markdown: math.markdown, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        let parsed = math.restoringFormulas(in: markdown)
        var root = Block(id: -1, kind: .paragraph)
        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var text = AttributedString(parsed[run.range])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { BlockView(block: $0) }
        }
        .textSelection(.enabled)
    }

    private struct BlockView: View {
        let block: Block
        var ordered = false

        private var contents: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(block.children) { BlockView(block: $0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder var body: some View {
            switch block.kind {
            case .thematicBreak:
                Divider().padding(.vertical, 6)
            case .header(let level):
                CodexMathText(text: block.text, fontSize: [28.0, 24, 21, 18, 16, 15][min(max(level, 1), 6) - 1])
                    .font(.system(size: [28.0, 24, 21, 18, 16, 15][min(max(level, 1), 6) - 1],
                                  weight: level <= 2 ? .bold : .semibold))
                    .foregroundStyle(level == 6 ? Color.secondary : Color.primary)
                    .padding(.top, level <= 2 ? 10 : 4)
                    .padding(.bottom, level <= 2 ? 4 : 0)
            case .orderedList, .unorderedList:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(block.children) { child in
                        BlockView(block: child, ordered: block.kind == .orderedList)
                    }
                }
            case .listItem(let ordinal):
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(ordered ? "\(ordinal)." : "•")
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .trailing)
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
                    Text(String(block.text.characters))
                        .font(.system(size: 13, design: .monospaced))
                        .padding(12)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            case .table(let columns):
                TableView(block: block, columns: columns)
            default:
                if block.children.isEmpty {
                    CodexMathText(text: block.text)
                        .font(.system(size: 15))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    contents
                }
            }
        }
    }

    private struct TableView: View {
        let block: Block
        let columns: [PresentationIntent.TableColumn]
        @State private var availableWidth: CGFloat = 820

        private var columnWidth: CGFloat {
            max(120, min(300, availableWidth / CGFloat(max(columns.count, 1))))
        }

        var body: some View {
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(columns.indices, id: \.self) { index in
                                let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                                CodexMathText(text: cell?.text ?? AttributedString())
                                    .font(.system(size: 15, weight: row.kind == .tableHeaderRow ? .semibold : .regular))
                                    .multilineTextAlignment(columns[index].alignment == .right ? .trailing
                                        : columns[index].alignment == .center ? .center : .leading)
                                    .frame(width: columnWidth - 24, alignment: columns[index].alignment == .right ? .trailing
                                        : columns[index].alignment == .center ? .center : .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(12)
                            }
                        }
                        .background(row.kind == .tableHeaderRow ? Color.secondary.opacity(0.12) : .clear)
                        Divider().gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        }
    }
}
