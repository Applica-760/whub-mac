import AppKit
import Combine
import SwiftUI
import WhubAgent

enum AgentBookPageStyle {
    static let pageInset: CGFloat = 28
    static let horizontalInset: CGFloat = 16
    static let pageGap: CGFloat = 32
    static let subpageThreshold: CGFloat = 1600
    static let previewAngle: CGFloat = 20 * .pi / 180

    static func perspectiveDistance(pageWidth: CGFloat) -> CGFloat { max(1000, pageWidth * 1.5) }
}

@MainActor
final class AgentBookPageLayout: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var spread = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var layoutError: String?
    private(set) var pages: [Page] = []
    private(set) var pageSize = CGSize.zero
    private(set) var headers: [Header] = []
    private(set) var promptControls: [Header] = []
    private(set) var contentBottoms: [CGFloat] = []
    private(set) var navigationRevision = 0
    private(set) var selectedPage = 0

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

    struct Prompt: Identifiable {
        let id: UUID
        let range: NSRange
        let text: NSAttributedString
        let size: CGSize
    }

    final class Page {
        let id: String
        let storage = NSTextStorage()
        let manager: NSLayoutManager = MarkdownLayoutManager()
        let container = NSTextContainer()
        private(set) var codes: [Code] = []
        private(set) var prompts: [Prompt] = []

        init(id: String) {
            self.id = id
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
        }

        func update(_ text: NSAttributedString, width: CGFloat) {
            container.containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            storage.setAttributedString(text)
            manager.ensureLayout(for: container)
            codes = []
            storage.enumerateAttribute(.markdownCodeSource, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let text = value as? String,
                      let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                      let id = storage.attribute(.agentBookCodeID, at: range.location, effectiveRange: nil) as? String else { return }
                codes.append(Code(id: id, range: range, text: text, size: attachment.bounds.size))
            }
            prompts = []
            storage.enumerateAttribute(.agentBookPromptSource, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let text = value as? NSAttributedString,
                      let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                      let id = storage.attribute(.agentBookPromptID, at: range.location, effectiveRange: nil) as? UUID else { return }
                prompts.append(Prompt(id: id, range: range, text: text, size: attachment.bounds.size))
            }

        }
    }

    private struct Input: Equatable {
        let id: UUID
        let agentName: String
        let prompt: String
        let images: [UUID]
        let additionalPrompts: [String]
        let additionalImages: [[UUID]]
        let history: [String]
        let answers: [AgentContent]
        let status: AgentExecutionStatus
        var isPromptExpanded: Bool
    }

    private var expandedPrompts = Set<UUID>()
    private var pendingPromptID: UUID?
    private var exchanges: [AgentExchange] = []
    private var agentName = ""
    private var inputs: [Input] = []
    private struct RenderedExchange {
        let input: Input
        let page: Page
        let size: CGSize
    }

    private var rendered: [RenderedExchange] = []
    private var renderedRevision = -1
    private var renderedNavigation = -1
    private var viewportSize = CGSize.zero
    private(set) var subpageSize = CGSize.zero
    private var appearance: ColorScheme?
    private var publication = 0
    var spreadCount: Int { max(1, pageCount) }

    var visiblePages: Range<Int> {
        let margin = viewportSize.width >= AgentBookPageStyle.subpageThreshold && subpageSize.width >= 220 ? 1 : 0
        return max(0, selectedPage - margin)..<min(pages.count, selectedPage + margin + 1)
    }

    func size(for index: Int) -> CGSize {
        pageSize
    }

    func displaySize(for index: Int) -> CGSize {
        index == selectedPage ? pageSize : subpageSize
    }

    func pageOrigin(_ index: Int, viewport: CGSize) -> CGPoint {
        let centerX = (viewport.width - pageSize.width) / 2
        let halfWidth = subpageSize.width / 2
        let angle = AgentBookPageStyle.previewAngle
        let distance = AgentBookPageStyle.perspectiveDistance(pageWidth: pageSize.width)
        // Pin the projected outer edge, rather than the unrotated view's frame, to the margin.
        let projectedHalfWidth = halfWidth * cos(angle) / (1 + halfWidth * sin(angle) / distance)
        let leftX = 8 - (halfWidth - projectedHalfWidth)
        let x: CGFloat
        if index < selectedPage { x = leftX }
        else if index > selectedPage { x = viewport.width - leftX - subpageSize.width }
        else { x = centerX }
        return CGPoint(x: floor(x), y: floor((viewport.height - displaySize(for: index).height) / 2))
    }

    func update(_ exchanges: [AgentExchange], agentName: String) {
        expandedPrompts.formIntersection(exchanges.map(\.id))
        let next = exchanges.map {
            Input(id: $0.id, agentName: agentName, prompt: $0.input.agentBookPrompt, images: $0.input.agentBookImages.map(\.id),
                  additionalPrompts: $0.additionalInputs.map { $0.input.agentBookPrompt },
                  additionalImages: $0.additionalInputs.map { $0.input.agentBookImages.map(\.id) },
                  history: $0.history.map { output in
                      output.agentBookTitle + (output.agentBookStatus == .failed ? "（失敗）" : "") + "\n" + output.agentBookText
                  }, answers: $0.answers.flatMap(\.agentBookContent), status: $0.status,
                  isPromptExpanded: expandedPrompts.contains($0.id))
        }
        self.exchanges = exchanges
        guard inputs != next else { return }
        self.agentName = agentName
        inputs = next
        revision += 1
    }

    static func collapsedPrompt(_ prompt: String) -> String? {
        let lines = prompt.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.count > 6 || prompt.count > 500 else { return nil }
        return String(lines.prefix(6).joined(separator: "\n").prefix(500)) + "…"
    }

    func isPromptExpanded(_ id: UUID) -> Bool { expandedPrompts.contains(id) }

    func exchange(_ id: UUID) -> AgentExchange? { exchanges.first { $0.id == id } }

    func togglePrompt(_ id: UUID) {
        guard let index = inputs.firstIndex(where: { $0.id == id }), Self.collapsedPrompt(inputs[index].prompt) != nil else { return }
        if !expandedPrompts.insert(id).inserted { expandedPrompts.remove(id) }
        inputs[index].isPromptExpanded = expandedPrompts.contains(id)
        pendingPromptID = id
        revision += 1
    }

    func selectPage(_ index: Int) {
        let next = min(max(0, index), max(0, pages.count - 1))
        guard next != selectedPage || spread != next else { return }
        selectedPage = next
        navigationRevision += 1
        spread = next
    }

    func move(_ offset: Int) {
        let current = selectedPage
        let next = min(max(0, current + offset), max(0, pages.count - 1))
        guard next != current else { return }
        selectPage(next)
    }

    @discardableResult
    func prepare(viewport: CGSize, colorScheme: ColorScheme) -> Bool {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 112, viewport.height > 112 else { return false }
        let width = min(1100, viewport.width >= AgentBookPageStyle.subpageThreshold ? viewport.width * 0.58 : viewport.width - 32)
        let size = CGSize(width: floor(width), height: floor(viewport.height - 16))
        guard renderedRevision != revision || renderedNavigation != navigationRevision
            || viewportSize != viewport || appearance != colorScheme else { return false }
        let readingID = rendered.indices.contains(selectedPage) ? rendered[selectedPage].input.id : nil
        let addedExchange = inputs.count > rendered.count
        let changedSize = viewportSize != viewport || appearance != colorScheme
        pageSize = size
        viewportSize = viewport
        let availableWidth = max(0, (viewport.width - size.width) / 2 - 40)
        let scale = min(0.82, min(0.76, availableWidth / size.width) * 1.08)
        subpageSize = CGSize(width: size.width * scale, height: size.height * scale)
        appearance = colorScheme
        var nextPage = min(selectedPage, max(0, inputs.count - 1))
        if addedExchange { nextPage = max(0, inputs.count - 1) }
        else if let readingID, let index = inputs.firstIndex(where: { $0.id == readingID }) { nextPage = index }
        if let pendingPromptID, let index = inputs.firstIndex(where: { $0.id == pendingPromptID }) { nextPage = index }
        selectedPage = nextPage
        updateDocument(colorScheme: colorScheme, rebuild: changedSize)
        updateControlFrames()
        pendingPromptID = nil
        publish(pageCount: max(1, pages.count), spread: nextPage, error: nil)
        return true
    }

    private func updateDocument(colorScheme: ColorScheme, rebuild: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: rendered.map { ($0.input.id, $0) })
        rendered = inputs.enumerated().map { index, input in
            let cached = previous[input.id]
            let size = size(for: index)
            let content = CGSize(width: max(1, size.width - 2 * AgentBookPageStyle.horizontalInset),
                                 height: max(1, size.height - 2 * AgentBookPageStyle.pageInset))
            let page = cached?.page ?? Page(id: input.id.uuidString)
            if rebuild || cached?.input != input || cached?.size != size {
                page.update(render(exchanges[index], input: input, content: content, colorScheme: colorScheme), width: content.width)
            }
            return RenderedExchange(input: input, page: page, size: size)
        }
        pages = rendered.map(\.page)
        renderedRevision = revision
        renderedNavigation = navigationRevision
    }

    private func updateControlFrames() {
        contentBottoms = pages.enumerated().map { index, page in
            min(size(for: index).height - 16, AgentBookPageStyle.pageInset + page.manager.usedRect(for: page.container).maxY)
        }
        headers = controlFrames(for: .agentBookHeaderExchangeID)
        promptControls = controlFrames(for: .agentBookPromptExchangeID)
    }

    private func controlFrames(for key: NSAttributedString.Key) -> [Header] {
        var controls: [Header] = []
        for (index, page) in pages.enumerated() {
            page.storage.enumerateAttribute(key, in: NSRange(location: 0, length: page.storage.length)) { value, range, _ in
                guard let id = value as? UUID else { return }
                let glyph = page.manager.glyphIndexForCharacter(at: range.location)
                let line = page.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                controls.append(Header(id: id, page: index,
                                      frame: CGRect(x: AgentBookPageStyle.horizontalInset, y: AgentBookPageStyle.pageInset + line.minY, width: max(1, size(for: index).width - 2 * AgentBookPageStyle.horizontalInset), height: 20)))
            }
        }
        return controls
    }

    private func publish(pageCount: Int, spread: Int, error: String?) {
        publication += 1
        let version = publication
        let navigation = navigationRevision
        // SwiftUI observes page navigation; defer publication until AppKit's layout pass has ended.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.publication == version else { return }
            self.pageCount = pageCount
            if self.navigationRevision == navigation { self.spread = spread }
            self.layoutError = error
        }
    }

    private func renderPrompt(_ groups: [[AgentInput]], id: UUID, content: CGSize) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 14
        for inputs in groups {
            if !inputs.agentBookPrompt.isEmpty {
                let table = NSTextTable()
                table.numberOfColumns = 1
                table.layoutAlgorithm = .fixedLayoutAlgorithm
                table.setValue(content.width, type: .absoluteValueType, for: .width)
                let bubble = AgentBookPromptBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
                bubble.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
                bubble.setWidth(12, type: .absoluteValueType, for: .padding)
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                style.textBlocks = [bubble]
                style.paragraphSpacing = 0
                let prompt = inputs.agentBookPrompt
                let text = NSMutableAttributedString(string: prompt + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
                ])
                let lastParagraph = (text.string as NSString).paragraphRange(for: NSRange(location: text.length - 1, length: 0))
                let lastStyle = style.mutableCopy() as! NSMutableParagraphStyle
                lastStyle.paragraphSpacing = paragraph.paragraphSpacing
                text.addAttribute(.paragraphStyle, value: lastStyle, range: lastParagraph)
                output.append(text)
            }
            for image in inputs.agentBookImages {
                let attachment = NSTextAttachment()
                attachment.image = image.image
                let size = image.image.size
                let scale = min(content.width / max(1, size.width), min(80, content.height - 24) / max(1, size.height))
                attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
                output.append(NSAttributedString(attachment: attachment))
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: 0, width: content.width,
                                   height: max(1, (content.height + 2 * AgentBookPageStyle.pageInset) * 0.15))
        attachment.attachmentCell = AgentBookContentCell()
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([.agentBookPromptSource: output, .agentBookPromptID: id], range: NSRange(location: 0, length: 1))
        result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        return result
    }

    private func render(_ turn: AgentExchange, input: Input, content: CGSize, colorScheme: ColorScheme) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        output.append(renderPrompt([turn.input] + turn.additionalInputs.map(\.input), id: turn.id, content: content))
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.minimumLineHeight = 20
        headerStyle.maximumLineHeight = 20
        headerStyle.paragraphSpacing = 8
        output.append(NSAttributedString(string: agentName + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.clear,
            .paragraphStyle: headerStyle, .agentBookHeaderExchangeID: turn.id
        ]))
        var hasAnswer = false
        for (answerIndex, source) in input.answers.enumerated() {
            let document = AgentBookRenderedContent(content: source, width: content.width, colorScheme: colorScheme)
            let text = NSMutableAttributedString(attributedString: document.text)
            for (codeIndex, code) in document.codes.enumerated().reversed() {
                let attachment = NSTextAttachment()
                attachment.bounds = CGRect(origin: .zero, size: code.size)
                attachment.attachmentCell = AgentBookContentCell()
                let replacement = NSMutableAttributedString(attachment: attachment)
                replacement.addAttributes([.markdownCodeSource: code.text,
                                           .agentBookCodeID: "\(turn.id)/\(answerIndex)/\(codeIndex)"],
                                          range: NSRange(location: 0, length: 1))
                if let style = text.attribute(.paragraphStyle, at: code.range.location, effectiveRange: nil) {
                    replacement.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: replacement.length))
                }
                text.replaceCharacters(in: code.range, with: replacement)
            }
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment,
                      text.attribute(.markdownCodeSource, at: range.location, effectiveRange: nil) == nil else { return }
                let size = attachment.bounds.size
                let scale = min(1, content.width / max(1, size.width))
                if scale < 1 {
                    attachment.bounds = CGRect(x: 0, y: attachment.bounds.minY * scale,
                                               width: size.width * scale, height: size.height * scale)
                }
            }
            if !hasAnswer {
                while text.length > 0 {
                    let range = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    guard (text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                    text.deleteCharacters(in: range)
                }
                guard text.length > 0 else { continue }
                let range = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                let style = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 0
                text.addAttribute(.paragraphStyle, value: style, range: range)
                hasAnswer = true
            }
            output.append(text)
        }
        return output
    }
}

private final class AgentBookContentCell: NSTextAttachmentCell {
    nonisolated override func cellSize() -> NSSize { attachment?.bounds.size ?? .zero }

    // Embedded scroll views draw the content; TextKit reserves their space.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}

private final class AgentBookPromptBlock: NSTextTableBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        backgroundColor?.setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
    }
}

extension NSAttributedString.Key {
    static let agentBookPromptSource = NSAttributedString.Key("whub.book.promptSource")
    static let agentBookPromptID = NSAttributedString.Key("whub.book.promptID")
    static let agentBookHeaderExchangeID = NSAttributedString.Key("whub.book.headerTurnID")
    static let agentBookCodeID = NSAttributedString.Key("whub.book.codeID")
    static let agentBookPromptExchangeID = NSAttributedString.Key("whub.book.promptTurnID")
}

private struct AgentBookRenderedContent {
    let text: NSAttributedString
    let codes: [MarkdownDocument.Code]

    init(content: AgentContent, width: CGFloat, colorScheme: ColorScheme) {
        switch content {
        case .markdown(let source):
            let document = MarkdownDocument(source: source, width: width, colorScheme: colorScheme)
            text = document.text
            codes = document.codes
        case .code:
            let document = MarkdownDocument(source: content.agentBookMarkdown, width: width, colorScheme: colorScheme)
            text = document.text
            codes = document.codes
        case .text(let source):
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = 10
            text = NSAttributedString(string: source + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ])
            codes = []
        case .image(let image):
            let attachment = NSTextAttachment()
            attachment.image = image.image
            let size = image.image.size
            let scale = min(1, width / max(1, size.width))
            attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            let output = NSMutableAttributedString(attachment: attachment)
            output.append(NSAttributedString(string: "\n"))
            text = output
            codes = []
        }
    }
}
