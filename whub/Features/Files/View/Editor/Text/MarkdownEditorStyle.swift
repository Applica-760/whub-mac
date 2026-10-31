import AppKit

enum MarkdownEditorStyle {
    static func apply(to storage: NSTextStorage, source: String) {
        guard let markdown = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true
        )) else { return }
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for index in bytes.indices where bytes[index] == 10 { lineStarts.append(index + 1) }
        for run in markdown.runs {
            guard let intent = run.inlinePresentationIntent, !intent.contains(.code),
                  let position = run.markdownSourcePosition,
                  position.startLine > 0, position.startLine <= lineStarts.count,
                  position.endLine > 0, position.endLine <= lineStarts.count else { continue }
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            let strike = intent.contains(.strikethrough)
            guard bold || italic || strike else { continue }
            let start = lineStarts[position.startLine - 1] + position.startColumn - 1
            let end = lineStarts[position.endLine - 1] + position.endColumn
            guard start >= 0, end >= start, end <= bytes.count,
                  let first = String.Index(source.utf8.index(source.utf8.startIndex, offsetBy: start), within: source),
                  let last = String.Index(source.utf8.index(source.utf8.startIndex, offsetBy: end), within: source) else { continue }
            let range = NSRange(first..<last, in: source)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: bold ? .bold : .regular)
            let color: NSColor = strike ? .secondaryLabelColor : bold ? .systemOrange : .systemPurple
            storage.addAttributes([
                .font: font,
                .foregroundColor: color,
                .obliqueness: italic ? 0.2 : 0,
                .strikethroughStyle: strike ? NSUnderlineStyle.single.rawValue : 0,
            ], range: range)
            let text = source as NSString
            for direction in [-1, 1] {
                var edge = direction < 0 ? range.location : NSMaxRange(range)
                var remaining = (bold: bold, italic: italic, strike: strike)
                while true {
                    let markers: [(String, Bool)] = [
                        ("~~", remaining.strike), ("~", remaining.strike),
                        ("*", remaining.italic), ("_", remaining.italic),
                        ("**", remaining.bold), ("__", remaining.bold),
                    ]
                    guard let marker = markers.first(where: { marker, enabled in
                        let length = (marker as NSString).length
                        let location = direction < 0 ? edge - length : edge
                        return enabled && location >= 0 && location + length <= text.length
                            && text.substring(with: NSRange(location: location, length: length)) == marker
                    })?.0 else { break }
                    let length = (marker as NSString).length
                    let location = direction < 0 ? edge - length : edge
                    storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: location, length: length))
                    edge = direction < 0 ? location : edge + length
                    if marker.contains("~") { remaining.strike = false }
                    else if length == 1 { remaining.italic = false }
                    else { remaining.bold = false }
                }
            }
        }
    }
}

