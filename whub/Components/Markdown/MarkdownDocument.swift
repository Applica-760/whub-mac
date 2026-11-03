import Foundation

/// Keep Markdown containers so nested lists and multi-paragraph quotes stay together.
struct MarkdownDocument {
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
        let math = MarkdownMathSource(source)
        guard let markdown = try? AttributedString(markdown: math.markdown, options: .init(interpretedSyntax: .full)) else {
            return [Block(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        let parsed = math.restoringFormulas(in: markdown)
        var root = Block(id: -1, kind: .paragraph)
        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if path.isEmpty {
                root.children.append(Block(id: -(root.children.count + 2), kind: .paragraph, text: text))
            } else {
                root.append(text, path: path[...])
            }
        }
        return root.children
    }

}

nonisolated struct MarkdownFormula: Hashable, Sendable {
    let source: String
    let latex: String?
    let display: Bool
}

nonisolated enum MarkdownFormulaAttribute: AttributedStringKey {
    typealias Value = MarkdownFormula
    static let name = "whub.formula"
}

/// Protect LaTeX from Markdown's underscore, backslash and line-break processing.
struct MarkdownMathSource {
    let markdown: String
    private let formulas: [(token: String, formula: MarkdownFormula)]

    init(_ source: String) {
        guard source.contains("$") else { markdown = source; formulas = []; return }
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for index in bytes.indices where bytes[index] == 10 { lineStarts.append(index + 1) }
        let parsed = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true
        ))
        let protected: [Range<Int>] = parsed?.runs.compactMap { run in
            let code = run.inlinePresentationIntent?.contains(.code) == true
                || run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { return true }; return false } == true
            guard code || run.link != nil, let position = run.markdownSourcePosition,
                  position.startLine > 0, position.startLine <= lineStarts.count,
                  position.endLine > 0, position.endLine <= lineStarts.count else { return nil }
            let start = lineStarts[position.startLine - 1] + max(0, position.startColumn - 1)
            let end = min(bytes.count, lineStarts[position.endLine - 1] + position.endColumn)
            return start..<max(start, end)
        } ?? []
        var prefix = "WHUBMATH"
        while source.contains(prefix) { prefix += "X" }
        var output: [UInt8] = []
        var found: [(String, MarkdownFormula)] = []
        var index = 0
        while index < bytes.count {
            if let range = protected.first(where: { $0.contains(index) }) {
                output.append(contentsOf: bytes[index..<range.upperBound])
                index = range.upperBound
                continue
            }
            if bytes[index] == 92, index + 1 < bytes.count {
                output.append(contentsOf: bytes[index...index + 1])
                index += 2
                continue
            }
            guard bytes[index] == 36 else { output.append(bytes[index]); index += 1; continue }
            let display = index + 1 < bytes.count && bytes[index + 1] == 36
            let delimiterCount = display ? 2 : 1
            let start = index + delimiterCount
            if !display, start == bytes.count || [9, 10, 13, 32].contains(bytes[start]) {
                output.append(bytes[index]); index += 1; continue
            }
            var end = start
            var closing: Int?
            while end < bytes.count {
                if protected.contains(where: { $0.contains(end) }) || (!display && [10, 13].contains(bytes[end])) { break }
                if bytes[end] == 92, end + 1 < bytes.count { end += 2; continue }
                if bytes[end] == 36 {
                    let doubled = end + 1 < bytes.count && bytes[end + 1] == 36
                    if display == doubled, end > start,
                       display || (![9, 32].contains(bytes[end - 1]) && (end + 1 == bytes.count || !(48...57).contains(bytes[end + 1]))) {
                        closing = end
                        break
                    }
                    if doubled { end += 2; continue }
                }
                end += 1
            }
            let finish = closing.map { $0 + delimiterCount } ?? end
            let original = String(decoding: bytes[index..<finish], as: UTF8.self)
            let latex = closing.map { String(decoding: bytes[start..<$0], as: UTF8.self) }
            let token = "\(prefix)\(found.count)END"
            found.append((token, MarkdownFormula(source: original, latex: latex, display: display)))
            output.append(contentsOf: token.utf8)
            index = finish
        }
        markdown = String(decoding: output, as: UTF8.self)
        formulas = found
    }

    func restoringFormulas(in markdown: AttributedString) -> AttributedString {
        var result = markdown
        for (token, formula) in formulas {
            guard let range = result.range(of: token) else { continue }
            var replacement = AttributedString(formula.source)
            if let attributes = result[range].runs.first?.attributes { replacement.mergeAttributes(attributes) }
            replacement[MarkdownFormulaAttribute.self] = formula
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
