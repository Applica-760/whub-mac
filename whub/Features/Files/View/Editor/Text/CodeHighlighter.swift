import AppKit
import Highlighter
import WhubGit

actor CodeHighlighter {
    static let shared = CodeHighlighter()
    private lazy var highlighter = Highlighter()

    nonisolated struct Request: Equatable, Sendable {
        let source: String
        let language: String?
        let dark: Bool
        let diffLines: [DiffLine]?
    }

    // Only immutable snapshots leave the actor; its parser and mutable buffers stay isolated.
    nonisolated struct Result: @unchecked Sendable {
        let text: NSAttributedString
    }

    func highlight(_ request: Request) -> Result? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let themeName = request.dark ? "night-owl" : "xcode"
            if highlighter?.theme.name != themeName {
                highlighter?.setTheme(themeName, withFont: font.fontName, ofSize: 13)
            }
            let highlighted = request.language.flatMap { highlighter?.highlight(request.source, as: $0) }
            guard !Task.isCancelled else { return nil }
            let text = NSMutableAttributedString(string: request.source, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ])
            if let highlighted, highlighted.string == request.source {
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attributes, range, _ in
                    var attributes = attributes
                    if request.language == "markdown" { attributes.removeValue(forKey: .font) }
                    text.addAttributes(attributes, range: range)
                }
            }
            if request.language == "markdown" { MarkdownEditorStyle.apply(to: text, source: request.source) }
            guard !Task.isCancelled else { return nil }
            if let diffLines = request.diffLines {
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = 20
                paragraph.maximumLineHeight = 20
                text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
                var offset = 0
                for line in diffLines {
                    let length = line.displayText.utf16.count
                    let color: NSColor? = switch line.change {
                    case .added: .systemGreen
                    case .deleted: .systemRed
                    case .modified: .systemOrange
                    case nil: nil
                    }
                    if let color {
                        text.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.18),
                                          range: NSRange(location: offset, length: length))
                    }
                    if line.foldedRange != nil {
                        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                          range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
            }
            return Result(text: NSAttributedString(attributedString: text))
        }
    }
}
