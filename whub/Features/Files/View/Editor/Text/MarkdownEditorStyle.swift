import AppKit

nonisolated enum MarkdownEditorStyle {
    static func apply(to storage: NSMutableAttributedString, source: String) {
        guard let markdown = try? AttributedString(markdown: source, options: .init(
            interpretedSyntax: .full, appliesSourcePositionAttributes: true
        )) else { return }
        // Markdown positions use UTF-8 columns; NSTextStorage ranges use UTF-16.
        var utf16Offsets = [Int](repeating: -1, count: source.utf8.count + 1)
        var byteOffset = 0
        var utf16Offset = 0
        var lineStarts = [0]
        utf16Offsets[0] = 0
        for scalar in source.unicodeScalars {
            byteOffset += scalar.utf8.count
            utf16Offset += scalar.value > 0xFFFF ? 2 : 1
            utf16Offsets[byteOffset] = utf16Offset
            if scalar.value == 10 { lineStarts.append(byteOffset) }
        }
        let text = source as NSString
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
            guard start >= 0, end >= start, end < utf16Offsets.count,
                  utf16Offsets[start] >= 0, utf16Offsets[end] >= 0 else { continue }
            let range = NSRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])
            let color: NSColor = strike ? .secondaryLabelColor : bold ? .systemOrange : .systemPurple
            storage.addAttribute(.foregroundColor, value: color, range: range)
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

