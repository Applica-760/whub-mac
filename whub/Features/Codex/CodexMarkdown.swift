import SwiftUI

/// Foundation parses Markdown; block boundaries provide readable native spacing.
struct CodexMarkdown: View {
    let source: String

    private struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        let components: [PresentationIntent.IntentType]

        var heading: Int? {
            for component in components {
                if case .header(let level) = component.kind { return level }
            }
            return nil
        }
        var isCode: Bool {
            components.contains { if case .codeBlock = $0.kind { return true }; return false }
        }
        var marker: String? {
            for component in components {
                if case .listItem(let ordinal) = component.kind {
                    return components.contains { if case .orderedList = $0.kind { return true }; return false }
                        ? "\(ordinal)." : "•"
                }
            }
            return nil
        }
    }

    private var blocks: [Block] {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, text: AttributedString(source), components: [])]
        }
        var result: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            let text = AttributedString(parsed[run.range])
            if result.last?.id == id {
                result[result.count - 1].text.append(text)
            } else {
                result.append(Block(id: id, text: text, components: components))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                if block.isCode {
                    ScrollView(.horizontal) {
                        Text(String(block.text.characters))
                            .font(.system(size: 13, design: .monospaced))
                            .padding(12)
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let marker = block.marker { Text(marker).foregroundStyle(.secondary) }
                        Text(block.text)
                            .font(block.heading.map { .system(size: $0 == 1 ? 24 : 19, weight: .semibold) } ?? .system(size: 15))
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}
