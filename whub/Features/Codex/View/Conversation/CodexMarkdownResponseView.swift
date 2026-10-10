import SwiftUI

/// Keep Markdown containers so nested lists and multi-paragraph quotes stay together.
struct CodexMarkdownResponseView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { BlockView(block: $0) }
        }
        .textSelection(.enabled)
    }

    struct BlockView: View {
        let block: Block
        var ordered = false
        var width: CGFloat? = nil
        @Environment(\.codexSelectionOrder) private var selectionOrder
        @Environment(\.codexSelectionSource) private var selectionSource

        private var contents: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(block.children.enumerated()), id: \.element.id) { index, child in
                    BlockView(block: child, width: width.map { $0 - (block.kind == .blockQuote ? 14 : 32) })
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
                        BlockView(block: child, ordered: block.kind == .orderedList, width: width)
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
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            case .table(let columns):
                TableView(block: block, columns: columns, fixedWidth: width)
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
        let block: Block
        let columns: [PresentationIntent.TableColumn]
        var fixedWidth: CGFloat?
        @Environment(\.codexSelectionSource) private var selectionSource
        @Environment(\.codexSelectionOrder) private var selectionOrder
        @State private var availableWidth: CGFloat = 820

        private var columnWidth: CGFloat {
            max(120, min(300, (fixedWidth ?? availableWidth) / CGFloat(max(columns.count, 1))))
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
