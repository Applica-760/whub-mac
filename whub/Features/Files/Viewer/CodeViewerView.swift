import AppKit
import Highlighter
import SwiftUI
import WhubCore

struct CodeViewerView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    @State private var diffURL: URL?
    @State private var hunks: [GitDiffHunk] = []
    @State private var diffErrorMessage: String?

    private static let languages: [String: String] = [
        "c": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "css": "css",
        "go": "go",
        "h": "c",
        "hpp": "cpp",
        "html": "xml",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "kt": "kotlin",
        "kts": "kotlin",
        "m": "objectivec",
        "md": "markdown",
        "mm": "objectivec",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "scss": "scss",
        "sh": "bash",
        "sql": "sql",
        "swift": "swift",
        "toml": "ini",
        "ts": "typescript",
        "tsx": "typescript",
        "xml": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "zsh": "bash",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let diffErrorMessage {
                Text(diffErrorMessage)
                    .foregroundStyle(.secondary)
            }
            Content(
                source: source,
                language: Self.languages[fileURL.pathExtension.lowercased()],
                hunks: diffURL == fileURL ? hunks : []
            )
        }
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID)) {
            diffURL = nil
            hunks = []
            diffErrorMessage = nil
            do {
                let loaded = try await Git.diff(at: fileURL)
                guard !Task.isCancelled else { return }
                hunks = loaded
                diffURL = fileURL
            } catch GitError.notRepository {
                return
            } catch {
                guard !Task.isCancelled else { return }
                diffErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CodeLoadID: Equatable {
    let fileURL: URL
    let refreshID: Int
}

@MainActor private let codeHighlighter = Highlighter()

private struct Content: NSViewRepresentable {
    let source: String
    let language: String?
    let hunks: [GitDiffHunk]

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Expected NSTextView")
        }
        textView.isEditable = false
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat(Float.greatestFiniteMagnitude), height: CGFloat(Float.greatestFiniteMagnitude))
        textView.textContainer?.size = textView.maxSize
        textView.textContainer?.widthTracksTextView = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let ruler = GitDiffRulerView(scrollView: scrollView, orientation: .verticalRuler)
        ruler.ruleThickness = 30
        ruler.reservedThicknessForMarkers = 0
        ruler.clientView = textView
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        codeHighlighter?.setTheme(
            dark ? "xcode-dusk" : "xcode",
            withFont: "Menlo-Regular",
            ofSize: 13
        )
        let highlighted = language.flatMap { codeHighlighter?.highlight(source, as: $0) }
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
        guard let ruler = scrollView.verticalRulerView as? GitDiffRulerView else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let numberWidth = (String(lineStarts.count) as NSString).size(withAttributes: [.font: font]).width + 16
        let thickness = numberWidth + 5
        if ruler.ruleThickness != thickness {
            ruler.ruleThickness = thickness
            scrollView.tile()
        }
        ruler.update(hunks: hunks, lineStarts: lineStarts, lineCount: lineCount)
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
            guard let lineRect = lineRect(line, textView: textView, layoutManager: layoutManager, textContainer: textContainer) else { continue }
            let rulerRect = convert(lineRect, from: textView)
            let number = String(line + 1) as NSString
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
                NSRect(x: bounds.maxX - 5, y: rulerY - 1, width: 5, height: 2).fill()
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
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        guard line >= 0, line < lineStarts.count else { return nil }
        if line == lineStarts.count - 1 && (textView.string.isEmpty || textView.string.hasSuffix("\n")) {
            return layoutManager.extraLineFragmentRect.offsetBy(
                dx: textView.textContainerOrigin.x,
                dy: textView.textContainerOrigin.y
            )
        }
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
