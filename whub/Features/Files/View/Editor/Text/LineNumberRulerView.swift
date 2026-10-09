import AppKit
import WhubCore

final class LineNumberRulerView: NSRulerView {
    private(set) var hunks: [LineDiffHunk] = []
    private var lineStarts = [0]
    private var lineCount = 0
    private var diffLines: [DiffLine]?

    func update(source: String, hunks: [LineDiffHunk], diffLines: [DiffLine]? = nil) {
        self.diffLines = diffLines
        var lineStarts = [0]
        for (offset, character) in source.utf16.enumerated() where character == 10 {
            lineStarts.append(offset + 1)
        }
        let lineCount = source.isEmpty ? 0 : lineStarts.count - (source.hasSuffix("\n") ? 1 : 0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let numberWidth = (String(max(999, lineStarts.count)) as NSString).size(withAttributes: [.font: font]).width + 16
        let thickness = numberWidth + 5
        if ruleThickness != thickness {
            ruleThickness = thickness
            scrollView?.tile()
        }
        self.hunks = hunks
        self.lineStarts = lineStarts
        self.lineCount = lineCount
        invalidateHashMarks()
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 2, y: bounds.minY, width: 2, height: bounds.height)
            .intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)

        let visible = textView.visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(at: characters.location)
        let last = min(lineIndex(at: characters.upperBound) + 1, lineStarts.count - 1)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for line in first...last {
            guard let lineRect = lineRect(line, textView: textView, layoutManager: layoutManager) else { continue }
            let rulerRect = convert(lineRect, from: textView)
            let numberValue: Int
            if let diffLines {
                guard diffLines.indices.contains(line), let value = diffLines[line].number else { continue }
                numberValue = value
                let color: NSColor? = switch diffLines[line].change {
                case .added: .systemGreen
                case .deleted: .systemRed
                case .modified: .systemOrange
                case nil: nil
                }
                if let color {
                    color.setFill()
                    NSRect(x: bounds.maxX - 4, y: rulerRect.minY, width: 3, height: rulerRect.height).fill()
                }
            } else { numberValue = line + 1 }
            let number = String(numberValue) as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(
                at: NSPoint(x: bounds.maxX - 13 - size.width, y: rulerRect.midY - size.height / 2),
                withAttributes: attributes
            )
        }

        for hunk in hunks {
            if hunk.newLines.isEmpty {
                let line = hunk.newLines.lowerBound
                guard line >= 0, line <= lineCount else { continue }
                let y: CGFloat
                if line < lineCount, let lineRect = lineRect(line, textView: textView, layoutManager: layoutManager) {
                    y = lineRect.minY
                } else if lineCount > 0,
                          let lastRect = lineRect(lineCount - 1, textView: textView, layoutManager: layoutManager) {
                    y = lastRect.maxY
                } else {
                    y = textView.textContainerOrigin.y
                }
                let rulerY = convert(NSPoint(x: 0, y: y), from: textView).y
                NSColor.systemRed.setFill()
                NSRect(x: bounds.maxX - 5, y: rulerY - 1, width: 5, height: 2).fill()
            } else {
                guard hunk.newLines.lowerBound >= 0,
                      hunk.newLines.upperBound <= lineCount,
                      let first = lineRect(hunk.newLines.lowerBound, textView: textView, layoutManager: layoutManager),
                      let last = lineRect(hunk.newLines.upperBound - 1, textView: textView, layoutManager: layoutManager) else { continue }
                let firstInRuler = convert(first, from: textView)
                let lastInRuler = convert(last, from: textView)
                let top = min(firstInRuler.minY, lastInRuler.minY)
                let bottom = max(firstInRuler.maxY, lastInRuler.maxY)
                (hunk.oldLines.isEmpty ? NSColor.systemGreen : .systemOrange).setFill()
                NSRect(x: bounds.maxX - 4, y: top, width: 3, height: bottom - top).fill()
            }
        }
    }

    private func lineIndex(at offset: Int) -> Int {
        var lower = 0
        var upper = lineStarts.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= offset { lower = middle }
            else { upper = middle }
        }
        return lower
    }

    private func lineRect(
        _ line: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> NSRect? {
        guard line >= 0, line < lineStarts.count else { return nil }
        if line == lineStarts.count - 1 && (textView.string.isEmpty || textView.string.hasSuffix("\n")) {
            return layoutManager.extraLineFragmentRect.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
        }
        let start = lineStarts[line]
        let glyph = layoutManager.glyphIndexForCharacter(at: start)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
}
