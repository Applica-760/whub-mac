import AppKit
import SwiftMath
import SwiftUI

nonisolated struct CodexFormula: Hashable, Sendable {
    let source: String
    let latex: String?
    let display: Bool
}

nonisolated enum CodexFormulaAttribute: AttributedStringKey {
    typealias Value = CodexFormula
    static let name = "whub.formula"
}

/// Protect LaTeX from Markdown's underscore, backslash and line-break processing.
struct CodexMathSource {
    let markdown: String
    private let formulas: [(token: String, formula: CodexFormula)]

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
        var found: [(String, CodexFormula)] = []
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
            found.append((token, CodexFormula(source: original, latex: latex, display: display)))
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
            replacement[CodexFormulaAttribute.self] = formula
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}

struct CodexMathText: View {
    let text: AttributedString
    var fontSize: CGFloat = 13
    @Environment(\.colorScheme) private var colorScheme

    private enum Segment {
        case text(AttributedString)
        case display(CodexFormula)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var inline = AttributedString()
        for run in text.runs {
            if let formula = run[CodexFormulaAttribute.self], formula.display, formula.latex != nil {
                if !inline.characters.isEmpty { result.append(.text(inline)); inline = AttributedString() }
                result.append(.display(formula))
            } else {
                inline.append(AttributedString(text[run.range]))
            }
        }
        if !inline.characters.isEmpty || result.isEmpty { result.append(.text(inline)) }
        return result
    }

    private func inlineText(_ source: AttributedString) -> Text {
        var result = Text("")
        for run in source.runs {
            let part: Text
            if let formula = run[CodexFormulaAttribute.self], let rendered = render(formula, size: fontSize) {
                part = Text(Image(nsImage: rendered.image))
                    .baselineOffset(-rendered.descent)
            } else {
                part = Text(AttributedString(source[run.range]))
            }
            result = Text("\(result)\(part)")
        }
        return result
    }

    var body: some View {
        let parts = segments
        if parts.count == 1, case .text(let source) = parts[0] {
            inlineText(source)
                .accessibilityLabel(Text(String(source.characters)))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(parts.indices, id: \.self) { index in
                    switch parts[index] {
                    case .text(let source):
                        inlineText(source)
                            .accessibilityLabel(Text(String(source.characters)))
                    case .display(let formula):
                        ScrollView(.horizontal) {
                            if let rendered = render(formula, size: 20) {
                                Image(nsImage: rendered.image).accessibilityLabel(Text(formula.source))
                            } else {
                                Text(formula.source).font(.system(size: fontSize, design: .monospaced))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private final class Rendered: NSObject {
        let image: NSImage
        let descent: CGFloat
        init(image: NSImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }

    private static let cache: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.countLimit = 128
        return cache
    }()

    private func render(_ formula: CodexFormula, size: CGFloat) -> Rendered? {
        guard let latex = formula.latex, !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = "\(size):\(colorScheme):\(formula.display):\(latex)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        var math = MathImage(latex: latex, fontSize: size,
                             textColor: colorScheme == .dark ? .white : .black,
                             labelMode: formula.display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout, image.size.width > 0, image.size.height > 0 else { return nil }
        let rendered = Rendered(image: image, descent: layout.descent)
        Self.cache.setObject(rendered, forKey: key)
        return rendered
    }
}
