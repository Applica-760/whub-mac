import AppKit
import Highlighter
import SwiftUI
import WhubCore

@MainActor private let codeHighlighter = Highlighter()

struct CodeViewerView: NSViewRepresentable {
    let fileURL: URL
    let language: String
    let hunks: [GitDiffHunk]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Expected NSTextView")
        }
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let ruler = GitDiffRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.ruleThickness = 5
        ruler.reservedThicknessForMarkers = 0
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let source = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "Unable to display this file"
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        codeHighlighter?.setTheme(
            dark ? "xcode-dusk" : "xcode",
            withFont: "Menlo-Regular",
            ofSize: 13
        )
        let highlighted = codeHighlighter?.highlight(source, as: language)
            ?? NSAttributedString(
                string: source,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        textView.textStorage?.setAttributedString(highlighted)
        var lineStarts = [0]
        for (offset, character) in source.utf16.enumerated() where character == 10 {
            lineStarts.append(offset + 1)
        }
        let lineCount = source.isEmpty ? 0 : lineStarts.count - (source.hasSuffix("\n") ? 1 : 0)
        (scrollView.verticalRulerView as? GitDiffRulerView)?.update(
            hunks: hunks,
            lineStarts: lineStarts,
            lineCount: lineCount
        )
    }
}

private final class GitDiffRulerView: NSRulerView {
    private var hunks: [GitDiffHunk] = []
    private var lineStarts = [0]
    private var lineCount = 0

    func update(hunks: [GitDiffHunk], lineStarts: [Int], lineCount: Int) {
        self.hunks = hunks
        self.lineStarts = lineStarts
        self.lineCount = lineCount
        invalidateHashMarks()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)

        for hunk in hunks {
            if hunk.newLines.isEmpty {
                let line = hunk.newLines.lowerBound
                guard line >= 0, line <= lineCount else { continue }
                let y: CGFloat
                if line < lineCount, let lineRect = lineRect(line, textView: textView, layoutManager: layoutManager, textContainer: textContainer) {
                    y = lineRect.minY
                } else if lineCount > 0,
                          let lastRect = lineRect(lineCount - 1, textView: textView, layoutManager: layoutManager, textContainer: textContainer) {
                    y = lastRect.maxY
                } else {
                    y = textView.textContainerOrigin.y
                }
                let rulerY = convert(NSPoint(x: 0, y: y), from: textView).y
                NSColor.systemRed.setFill()
                NSRect(x: 0, y: rulerY - 1, width: bounds.width, height: 2).fill()
            } else {
                guard hunk.newLines.lowerBound >= 0,
                      hunk.newLines.upperBound <= lineCount,
                      let first = lineRect(hunk.newLines.lowerBound, textView: textView, layoutManager: layoutManager, textContainer: textContainer),
                      let last = lineRect(hunk.newLines.upperBound - 1, textView: textView, layoutManager: layoutManager, textContainer: textContainer) else { continue }
                let firstInRuler = convert(first, from: textView)
                let lastInRuler = convert(last, from: textView)
                let top = min(firstInRuler.minY, lastInRuler.minY)
                let bottom = max(firstInRuler.maxY, lastInRuler.maxY)
                (hunk.oldLines.isEmpty ? NSColor.systemGreen : .systemOrange).setFill()
                NSRect(x: 1, y: top, width: 3, height: bottom - top).fill()
            }
        }
    }

    private func lineRect(
        _ line: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        guard line >= 0, line < lineCount else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : (textView.string as NSString).length
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: start, length: end - start),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }
}
