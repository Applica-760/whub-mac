import AppKit
import Combine
import SwiftUI

enum CodexBookLayout {
    static let pageInset: CGFloat = 28
    static let pageGap: CGFloat = 32
    static let codeInset: CGFloat = 12
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static var codeLineHeight: CGFloat { ceil(codeFont.ascender - codeFont.descender + codeFont.leading) }
}

@MainActor
final class CodexBookDocument: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var spread = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var layoutError: String?
    let storage = NSTextStorage()
    let manager: NSLayoutManager = CodexBookLayoutManager()
    private(set) var ranges: [NSRange] = []
    private(set) var pageSize = CGSize.zero
    private(set) var codes: [Code] = []
    private(set) var headers: [Header] = []
    private(set) var contentBottoms: [CGFloat] = []
    private(set) var navigationRevision = 0

    struct Header: Identifiable {
        let id: UUID
        let page: Int
        let frame: CGRect
    }

    struct Code: Identifiable {
        let id: String
        let range: NSRange
        let text: String
        let size: CGSize
    }

    struct Anchor {
        let turnID: UUID
        let offset: Int
    }

    private struct Input: Equatable {
        let id: UUID
        let prompt: String
        let images: [UUID]
        let answers: [String]
    }

    private var turns: [CodexTurn] = []
    private var inputs: [Input] = []
    private struct RenderedTurn {
        let input: Input
        let text: NSAttributedString
    }

    private var rendered: [RenderedTurn] = []
    private var turnRanges: [(UUID, NSRange)] = []
    private var renderedRevision = -1
    private var appearance: ColorScheme?
    private var publication = 0
    var spreadCount: Int { max(1, (pageCount + 1) / 2) }

    init() { storage.addLayoutManager(manager) }

    func update(_ turns: [CodexTurn]) {
        let next = turns.map {
            Input(id: $0.id, prompt: $0.displayPrompt, images: $0.images.map(\.id),
                  answers: $0.answers.map(\.displayMarkdown))
        }
        guard inputs != next else { return }
        self.turns = turns
        inputs = next
        revision += 1
    }

    func move(_ offset: Int) {
        let next = min(max(0, spread + offset), spreadCount - 1)
        guard next != spread else { return }
        navigationRevision += 1
        spread = next
    }

    func anchor(at location: Int) -> Anchor? {
        guard let entry = turnRanges.last(where: { $0.1.location <= location }) else { return nil }
        return Anchor(turnID: entry.0, offset: min(location - entry.1.location, entry.1.length))
    }

    func location(of anchor: Anchor) -> Int? {
        guard let entry = turnRanges.first(where: { $0.0 == anchor.turnID }) else { return nil }
        return entry.1.location + min(anchor.offset, entry.1.length)
    }

    @discardableResult
    func prepare(viewport: CGSize, colorScheme: ColorScheme) -> Bool {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 112, viewport.height > 112 else { return false }
        let size = CGSize(width: floor((viewport.width - CodexBookLayout.pageGap) / 2), height: floor(viewport.height))
        guard renderedRevision != revision || pageSize != size || appearance != colorScheme else { return false }
        let reading = ranges.indices.contains(spread * 2) ? anchor(at: ranges[spread * 2].location) : nil
        let initial = rendered.isEmpty && !inputs.isEmpty
        let changedSize = pageSize != size || appearance != colorScheme
        pageSize = size
        appearance = colorScheme
        let content = CGSize(width: max(1, size.width - 2 * CodexBookLayout.pageInset),
                             height: max(1, size.height - 2 * CodexBookLayout.pageInset))
        updateDocument(content: content, colorScheme: colorScheme, rebuild: changedSize)
        let failure = paginate(content: content)
        updateControlFrames(content: content)
        var nextSpread = min(spread, max(0, (ranges.count - 1) / 2))
        if initial { nextSpread = max(0, (ranges.count - 1) / 2) }
        else if let reading, let position = location(of: reading),
                let page = ranges.firstIndex(where: { NSLocationInRange(position, $0) }) { nextSpread = page / 2 }
        publish(pageCount: ranges.count, spread: nextSpread, error: failure)
        return true
    }

    private func updateDocument(content: CGSize, colorScheme: ColorScheme, rebuild: Bool) {
        let output = NSMutableAttributedString(string: "")
        var nextRendered: [RenderedTurn] = []
        var nextRanges: [(UUID, NSRange)] = []
        var firstChanged = 0
        for (index, input) in inputs.enumerated() {
            let cached = !rebuild && rendered.indices.contains(index) && rendered[index].input == input
            let part = cached ? rendered[index].text : render(turns[index], input: input, content: content, colorScheme: colorScheme)
            if cached && firstChanged == index { firstChanged += 1 }
            nextRanges.append((input.id, NSRange(location: output.length, length: part.length)))
            output.append(part)
            nextRendered.append(RenderedTurn(input: input, text: part))
        }
        let prefix = rendered.prefix(firstChanged).reduce(0) { $0 + $1.text.length }
        storage.replaceCharacters(in: NSRange(location: prefix, length: storage.length - prefix),
                                  with: output.attributedSubstring(from: NSRange(location: prefix, length: output.length - prefix)))
        rendered = nextRendered
        turnRanges = nextRanges
        renderedRevision = revision
        codes = []
        storage.enumerateAttribute(.codexBookCodeSource, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let text = value as? String,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  let id = storage.attribute(.codexNativeCodeID, at: range.location, effectiveRange: nil) as? String else { return }
            codes.append(Code(id: id, range: range, text: text, size: attachment.bounds.size))
        }
    }

    private func paginate(content: CGSize) -> String? {
        for container in manager.textContainers { container.containerSize = content }
        ranges = []
        var end = 0
        var failure: String?
        repeat {
            let index = ranges.count
            if index == manager.textContainers.count {
                let container = NSTextContainer(containerSize: content)
                container.lineFragmentPadding = 0
                container.widthTracksTextView = false
                container.heightTracksTextView = false
                manager.addTextContainer(container)
            }
            let container = manager.textContainers[index]
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            ranges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            let next = NSMaxRange(glyphs)
            if next <= end && end < manager.numberOfGlyphs {
                failure = "このページの内容を配置できません。ウィンドウを広げてください。"
                break
            }
            end = next
        } while end < manager.numberOfGlyphs
        while manager.textContainers.count > ranges.count {
            manager.removeTextContainer(at: manager.textContainers.count - 1)
        }
        return failure
    }

    private func updateControlFrames(content: CGSize) {
        contentBottoms = manager.textContainers.map {
            min(pageSize.height - 16, CodexBookLayout.pageInset + manager.usedRect(for: $0).maxY)
        }
        headers = []
        storage.enumerateAttribute(.codexNativeHeaderTurnID, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? UUID,
                  let page = ranges.firstIndex(where: { NSLocationInRange(range.location, $0) }) else { return }
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            headers.append(Header(id: id, page: page,
                                  frame: CGRect(x: CodexBookLayout.pageInset, y: CodexBookLayout.pageInset + line.minY, width: content.width, height: 20)))
        }
    }

    private func publish(pageCount: Int, spread: Int, error: String?) {
        publication += 1
        let version = publication
        // SwiftUI observes page navigation; defer publication until AppKit's layout pass has ended.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.publication == version else { return }
            self.pageCount = pageCount
            self.spread = spread
            self.layoutError = error
        }
    }

    private func render(_ turn: CodexTurn, input: Input, content: CGSize, colorScheme: ColorScheme) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 14
        if !input.prompt.isEmpty {
            // A table cell can continue across text containers; a plain text block cannot.
            let table = NSTextTable()
            table.numberOfColumns = 1
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.setValue(content.width, type: .absoluteValueType, for: .width)
            let bubble = CodexBookPromptBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            bubble.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
            bubble.setWidth(12, type: .absoluteValueType, for: .padding)
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.textBlocks = [bubble]
            output.append(NSAttributedString(string: input.prompt + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ]))
        }
        for image in turn.images {
            let attachment = NSTextAttachment()
            attachment.image = image.image
            let size = image.image.size
            let scale = min(content.width / max(1, size.width), min(80, content.height - 24) / max(1, size.height))
            attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            output.append(NSAttributedString(attachment: attachment))
            output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }
        let headerStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
        headerStyle.minimumLineHeight = 20
        headerStyle.maximumLineHeight = 20
        headerStyle.paragraphSpacing = 8
        output.append(NSAttributedString(string: "Codex\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.clear,
            .paragraphStyle: headerStyle, .codexNativeHeaderTurnID: turn.id
        ]))
        for (answerIndex, source) in input.answers.enumerated() {
            let document = CodexMarkdownDocument(source: source, width: content.width, colorScheme: colorScheme)
            let text = NSMutableAttributedString(attributedString: document.text)
            let lineHeight = CodexBookLayout.codeLineHeight
            let linesPerPage = max(1, Int((content.height - 2 * CodexBookLayout.codeInset - 16) / lineHeight))
            for (codeIndex, code) in document.codes.enumerated().reversed() {
                let lines = code.text.components(separatedBy: "\n")
                let replacement = NSMutableAttributedString(string: "")
                for start in stride(from: 0, to: lines.count, by: linesPerPage) {
                    let end = min(lines.count, start + linesPerPage)
                    let chunk = lines[start..<end].joined(separator: "\n") + (end < lines.count ? "\n" : "")
                    let attachment = NSTextAttachment()
                    attachment.bounds = CGRect(x: 0, y: 0, width: code.size.width,
                                               height: CGFloat(end - start) * lineHeight + 2 * CodexBookLayout.codeInset)
                    let part = NSMutableAttributedString(attachment: attachment)
                    part.addAttributes([.codexBookCodeSource: chunk,
                                        .codexNativeCodeID: "\(turn.id)/\(answerIndex)/\(codeIndex)/\(start)"],
                                       range: NSRange(location: 0, length: 1))
                    replacement.append(part)
                    if end < lines.count { replacement.append(NSAttributedString(string: "\n")) }
                }
                if let style = text.attribute(.paragraphStyle, at: code.range.location, effectiveRange: nil) {
                    replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: replacement.length))
                }
                text.replaceCharacters(in: code.range, with: replacement)
            }
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment,
                      text.attribute(.codexBookCodeSource, at: range.location, effectiveRange: nil) == nil else { return }
                let size = attachment.bounds.size
                let scale = min(1, min(content.width / max(1, size.width), (content.height - 24) / max(1, size.height)))
                if scale < 1 {
                    attachment.bounds = CGRect(x: 0, y: attachment.bounds.minY * scale,
                                               width: size.width * scale, height: size.height * scale)
                }
            }
            output.append(text)
        }
        return output
    }
}

private final class CodexBookPromptBlock: NSTextTableBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        backgroundColor?.setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
    }
}

private final class CodexBookLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let background = storage.attribute(.codexInlineCodeBackground, at: charRange.location,
                                                 effectiveRange: nil) as? NSColor,
              background == color else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // Selection and other backgrounds retain AppKit's standard drawing.
        for index in 0..<rectCount {
            NSBezierPath(roundedRect: rectArray[index], xRadius: 4, yRadius: 4).fill()
        }
    }
}

private extension NSAttributedString.Key {
    static let codexNativeHeaderTurnID = NSAttributedString.Key("whub.book.headerTurnID")
    static let codexNativeCodeID = NSAttributedString.Key("whub.book.codeID")
}
