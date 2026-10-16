import AppKit
import Combine
import SwiftUI

struct AgentBookExchangeView: View {
    @ObservedObject var store: AgentStore
    let agentName: String
    @Binding var spread: Int
    let pageCountChanged: (Int) -> Void
    let focus: AgentBookFocus
    var featureActivity: RetainedPageActivity? = nil
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @StateObject private var book = AgentBookDocument()
    @State private var sessionActive = true
    @State private var featureActive = true

    private var visiblePages: Range<Int> { (book.spread * 2)..<min(book.pageCount, book.spread * 2 + 2) }
    private var canInteract: Bool { isActive && sessionActive && featureActive }
    private var approval: AgentRequest? {
        store.exchanges.last(where: { $0.status == .running })?.pendingRequests.first(where: \.isApproval)
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentBookTextView(book: book, focus: focus)
                .overlay(alignment: .top) {
                    GeometryReader { geometry in
                        Rectangle().fill(.secondary.opacity(0.18))
                            .frame(width: 1, height: max(0, geometry.size.height - 20))
                            .position(x: geometry.size.width / 2, y: 20 + max(0, geometry.size.height - 20) / 2)
                    }
                    .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        ForEach(book.promptControls.filter { visiblePages.contains($0.page) }) { control in
                            Button(book.isPromptExpanded(control.id) ? "折りたたむ" : "全文を表示",
                                   systemImage: book.isPromptExpanded(control.id) ? "chevron.up" : "chevron.down") {
                                focus.activateReading()
                                book.togglePrompt(control.id)
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .disabled(!canInteract)
                            .frame(width: control.frame.width, height: control.frame.height, alignment: .leading)
                            .offset(x: pageX(control.page) + control.frame.minX, y: control.frame.minY)
                        }
                        ForEach(book.headers.filter { visiblePages.contains($0.page) }) { header in
                            if let exchange = store.exchanges.first(where: { $0.id == header.id }) {
                                AgentBookExchangeHeader(exchange: exchange, agentName: agentName, isActive: canInteract)
                                    .frame(width: header.frame.width, height: header.frame.height)
                                    .offset(x: pageX(header.page) + header.frame.minX, y: header.frame.minY)
                            }
                        }
                        if let contentBottom = book.contentBottoms.last {
                            AgentBookApprovalEntryView(request: approval,
                                pageSize: book.pageSize, contentBottom: contentBottom, scale: 1,
                                isActive: canInteract && store.isConnected && visiblePages.contains(book.pageCount - 1),
                                sessionActivity: activity, featureActivity: featureActivity,
                                isResponding: approval.map { store.respondingRequestIDs.contains($0.id) } ?? false,
                                decide: { request, allow in
                                    guard canInteract else { return }
                                    Task { await store.respond(to: request.id, with: .approval(allow: allow)) }
                                })
                                .offset(x: pageX(book.pageCount - 1))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            if let error = book.layoutError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .background(AgentBookPageKeys(focus: focus, isActive: { canInteract },
                                      activateInput: focus.activateInput, move: book.move))
        .padding(.bottom, 64)
        .onReceive(store.$exchanges.throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) {
            updateBook($0)
        }
        .onChange(of: store.id) { _, _ in updateBook(store.exchanges) }
        .onChange(of: agentName) { _, _ in updateBook(store.exchanges) }
        .onChange(of: isActive) { _, active in if active { updateBook(store.exchanges) } }
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) {
            sessionActive = $0
            if $0 { updateBook(store.exchanges) }
        }
        .onReceive(featureActivity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) {
            featureActive = $0
            if $0 { updateBook(store.exchanges) }
        }
        .onChange(of: spread) { _, next in
            guard canInteract, next != book.spread else { return }
            focus.activateReading()
            book.move(next - book.spread)
        }
        .onReceive(book.$spread.removeDuplicates()) { spread = $0 }
        .onReceive(book.$pageCount.removeDuplicates()) { pageCountChanged($0) }
    }

    private func pageX(_ page: Int) -> CGFloat {
        CGFloat(page - book.spread * 2) * (book.pageSize.width + CodexBookLayout.pageGap)
    }

    private func updateBook(_ exchanges: [AgentExchange]) {
        guard canInteract, activity?.isActive.value != false, featureActivity?.isActive.value != false else { return }
        book.update(exchanges, agentName: agentName)
    }
}

private struct AgentBookExchangeHeader: View {
    let exchange: AgentExchange
    let agentName: String
    let isActive: Bool
    @State private var showsHistory = false

    var body: some View {
        HStack {
            Text(agentName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            ZStack {
                if exchange.status == .running {
                    ProgressView().controlSize(.mini).accessibilityLabel("応答を生成中")
                }
            }
            .frame(width: 16, height: 16)
            Button("作業履歴", systemImage: "terminal") { showsHistory.toggle() }
                .font(.caption).buttonStyle(.plain)
                .popover(isPresented: $showsHistory) { history }
            Button("回答をコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.answers.map(\.agentBookMarkdown).joined(separator: "\n\n"), forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .onChange(of: isActive) { _, active in
            if !active { showsHistory = false }
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("作業履歴").font(.headline)
                if !exchange.history.isEmpty {
                    Text(exchange.input.agentBookPrompt).font(.callout.weight(.semibold)).lineLimit(2)
                    ForEach(exchange.history) { output in
                        AgentBookOutputView(output: output)
                    }
                }
            }.padding(20)
        }
        .frame(width: 480, height: 440)
    }
}

@MainActor
private final class AgentBookDocument: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var spread = 0
    @Published private(set) var pageCount = 1
    @Published private(set) var layoutError: String?
    let storage = NSTextStorage()
    let manager: NSLayoutManager = AgentBookLayoutManager()
    private(set) var ranges: [NSRange] = []
    private(set) var pageSize = CGSize.zero
    private(set) var codes: [Code] = []
    private(set) var headers: [Header] = []
    private(set) var promptControls: [Header] = []
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
        let exchangeID: UUID
        let offset: Int
    }

    private struct Input: Equatable {
        let id: UUID
        let agentName: String
        let prompt: String
        let images: [UUID]
        let answers: [AgentContent]
        var isPromptExpanded: Bool
    }

    private var expandedPrompts = Set<UUID>()
    private var pendingPromptID: UUID?
    private var exchanges: [AgentExchange] = []
    private var agentName = ""
    private var inputs: [Input] = []
    private struct RenderedExchange {
        let input: Input
        let text: NSAttributedString
    }

    private var rendered: [RenderedExchange] = []
    private var exchangeRanges: [(UUID, NSRange)] = []
    private var renderedRevision = -1
    private var appearance: ColorScheme?
    private var publication = 0
    var spreadCount: Int { max(1, (pageCount + 1) / 2) }

    init() { storage.addLayoutManager(manager) }

    func update(_ exchanges: [AgentExchange], agentName: String) {
        expandedPrompts.formIntersection(exchanges.map(\.id))
        let next = exchanges.map {
            Input(id: $0.id, agentName: agentName, prompt: $0.input.agentBookPrompt, images: $0.input.agentBookImages.map(\.id),
                  answers: $0.answers.flatMap(\.agentBookContent), isPromptExpanded: expandedPrompts.contains($0.id))
        }
        guard inputs != next else { return }
        self.agentName = agentName
        self.exchanges = exchanges
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

    func togglePrompt(_ id: UUID) {
        guard let index = inputs.firstIndex(where: { $0.id == id }), Self.collapsedPrompt(inputs[index].prompt) != nil else { return }
        if !expandedPrompts.insert(id).inserted { expandedPrompts.remove(id) }
        inputs[index].isPromptExpanded = expandedPrompts.contains(id)
        pendingPromptID = id
        revision += 1
    }

    func move(_ offset: Int) {
        let next = min(max(0, spread + offset), spreadCount - 1)
        guard next != spread else { return }
        navigationRevision += 1
        spread = next
    }

    func anchor(at location: Int) -> Anchor? {
        guard let entry = exchangeRanges.last(where: { $0.1.location <= location }) else { return nil }
        return Anchor(exchangeID: entry.0, offset: min(location - entry.1.location, entry.1.length))
    }

    func location(of anchor: Anchor) -> Int? {
        guard let entry = exchangeRanges.first(where: { $0.0 == anchor.exchangeID }) else { return nil }
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
        if let pendingPromptID, let control = promptControls.first(where: { $0.id == pendingPromptID }) {
            nextSpread = control.page / 2
        }
        pendingPromptID = nil
        publish(pageCount: ranges.count, spread: nextSpread, error: failure)
        return true
    }

    private func updateDocument(content: CGSize, colorScheme: ColorScheme, rebuild: Bool) {
        let output = NSMutableAttributedString(string: "")
        var nextRendered: [RenderedExchange] = []
        var nextRanges: [(UUID, NSRange)] = []
        var firstChanged = 0
        for (index, input) in inputs.enumerated() {
            let cached = !rebuild && rendered.indices.contains(index) && rendered[index].input == input
            let part = cached ? rendered[index].text : render(exchanges[index], input: input, content: content, colorScheme: colorScheme)
            if cached && firstChanged == index { firstChanged += 1 }
            nextRanges.append((input.id, NSRange(location: output.length, length: part.length)))
            output.append(part)
            nextRendered.append(RenderedExchange(input: input, text: part))
        }
        let prefix = rendered.prefix(firstChanged).reduce(0) { $0 + $1.text.length }
        storage.replaceCharacters(in: NSRange(location: prefix, length: storage.length - prefix),
                                  with: output.attributedSubstring(from: NSRange(location: prefix, length: output.length - prefix)))
        rendered = nextRendered
        exchangeRanges = nextRanges
        renderedRevision = revision
        codes = []
        storage.enumerateAttribute(.codexBookCodeSource, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let text = value as? String,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  let id = storage.attribute(.agentBookCodeID, at: range.location, effectiveRange: nil) as? String else { return }
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
        headers = controlFrames(for: .agentBookHeaderExchangeID, content: content)
        promptControls = controlFrames(for: .agentBookPromptExchangeID, content: content)
    }

    private func controlFrames(for key: NSAttributedString.Key, content: CGSize) -> [Header] {
        var controls: [Header] = []
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? UUID,
                  let page = ranges.firstIndex(where: { NSLocationInRange(range.location, $0) }) else { return }
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            controls.append(Header(id: id, page: page,
                                  frame: CGRect(x: CodexBookLayout.pageInset, y: CodexBookLayout.pageInset + line.minY, width: content.width, height: 20)))
        }
        return controls
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

    private func render(_ turn: AgentExchange, input: Input, content: CGSize, colorScheme: ColorScheme) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 14
        if !input.prompt.isEmpty {
            let collapsed = Self.collapsedPrompt(input.prompt)
            if collapsed != nil {
                let controlStyle = paragraph.mutableCopy() as! NSMutableParagraphStyle
                controlStyle.minimumLineHeight = 20
                controlStyle.maximumLineHeight = 20
                controlStyle.paragraphSpacing = 8
                output.append(NSAttributedString(string: "\u{200B}\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.clear,
                    .paragraphStyle: controlStyle, .agentBookPromptExchangeID: turn.id
                ]))
            }
            // A table cell can continue across text containers; a plain text block cannot.
            let table = NSTextTable()
            table.numberOfColumns = 1
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.setValue(content.width, type: .absoluteValueType, for: .width)
            let bubble = AgentBookPromptBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            bubble.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
            bubble.setWidth(12, type: .absoluteValueType, for: .padding)
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            style.textBlocks = [bubble]
            let prompt = input.isPromptExpanded ? input.prompt : collapsed ?? input.prompt
            output.append(NSAttributedString(string: prompt + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ]))
        }
        for image in turn.input.agentBookImages {
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
        output.append(NSAttributedString(string: agentName + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.clear,
            .paragraphStyle: headerStyle, .agentBookHeaderExchangeID: turn.id
        ]))
        for (answerIndex, source) in input.answers.enumerated() {
            let document = AgentBookRenderedContent(content: source, width: content.width, colorScheme: colorScheme)
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
                    attachment.attachmentCell = AgentBookCodeCell()
                    let part = NSMutableAttributedString(attachment: attachment)
                    part.addAttributes([.codexBookCodeSource: chunk,
                                        .agentBookCodeID: "\(turn.id)/\(answerIndex)/\(codeIndex)/\(start)"],
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

private final class AgentBookCodeCell: NSTextAttachmentCell {
    nonisolated override func cellSize() -> NSSize { attachment?.bounds.size ?? .zero }

    // The code view draws the content; the cell reserves its space in TextKit 1.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}

private final class AgentBookPromptBlock: NSTextTableBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        backgroundColor?.setFill()
        NSBezierPath(roundedRect: frameRect, xRadius: 8, yRadius: 8).fill()
    }
}

private final class AgentBookLayoutManager: NSLayoutManager {
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
    static let agentBookHeaderExchangeID = NSAttributedString.Key("whub.book.headerTurnID")
    static let agentBookCodeID = NSAttributedString.Key("whub.book.codeID")
    static let agentBookPromptExchangeID = NSAttributedString.Key("whub.book.promptTurnID")
}

private struct AgentBookRenderedContent {
    let text: NSAttributedString
    let codes: [CodexMarkdownDocument.Code]

    init(content: AgentContent, width: CGFloat, colorScheme: ColorScheme) {
        switch content {
        case .markdown(let source):
            let document = CodexMarkdownDocument(source: source, width: width, colorScheme: colorScheme)
            text = document.text
            codes = document.codes
        case .code:
            let document = CodexMarkdownDocument(source: content.agentBookMarkdown, width: width, colorScheme: colorScheme)
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

private struct AgentBookTextView: NSViewRepresentable {
    @ObservedObject var book: AgentBookDocument
    let focus: AgentBookFocus
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> AgentBookTextSurface { AgentBookTextSurface(book: book) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentBookTextSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func updateNSView(_ view: AgentBookTextSurface, context: Context) {
        focus.readingView = view
        view.colorScheme = colorScheme
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: AgentBookTextSurface, coordinator: ()) {
        if view.isReading(in: view.window) { view.window?.makeFirstResponder(nil) }
    }
}

private final class AgentBookTextSurface: NSView, AgentBookReadingSurface {
    private let book: AgentBookDocument
    var colorScheme: ColorScheme = .light
    private var pages: [AgentBookNativeTextView] = []
    private var codeViews: [String: NSHostingView<AgentBookCodeBlock>] = [:]
    private var navigationRevision = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func isReading(in window: NSWindow?) -> Bool {
        guard let window, self.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.firstResponder === self { return true }
        guard let text = window.firstResponder as? NSTextView, !text.isHiddenOrHasHiddenAncestor else { return false }
        return text.isDescendant(of: self)
    }

    func activateReading() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        if let page = pages.first(where: { !$0.isHidden }) { window?.makeFirstResponder(page) }
        else { window?.makeFirstResponder(self) }
    }

    override func mouseDown(with event: NSEvent) { activateReading() }
    @objc func copy(_ sender: Any?) { pages.first(where: { !$0.isHidden })?.copy(sender) }

    override func selectAll(_ sender: Any?) {
        let first = book.spread * 2
        guard book.ranges.indices.contains(first), let page = pages.first(where: { !$0.isHidden }) else { return }
        let start = book.ranges[first].location
        let end = NSMaxRange(book.ranges[min(first + 1, book.ranges.count - 1)])
        page.setSelectedRange(NSRange(location: start, length: end - start))
        activateReading()
    }

    init(book: AgentBookDocument) {
        self.book = book
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let wasReading = isReading(in: window)
        let selected = pages.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        let startAnchor = book.anchor(at: selected.location)
        let endAnchor = book.anchor(at: NSMaxRange(selected))
        let changed = book.prepare(viewport: bounds.size, colorScheme: colorScheme)
        let containers = book.manager.textContainers
        while pages.count > containers.count { pages.removeLast().removeFromSuperview() }
        while pages.count < containers.count {
            let page = AgentBookNativeTextView(frame: .zero, textContainer: containers[pages.count])
            page.readingSurface = self
            page.isEditable = false
            page.isSelectable = true
            page.isRichText = true
            page.isVerticallyResizable = false
            page.isHorizontallyResizable = false
            page.textContainerInset = NSSize(width: CodexBookLayout.pageInset, height: CodexBookLayout.pageInset)
            page.drawsBackground = false
            page.autoresizingMask = []
            addSubview(page)
            pages.append(page)
        }
        if changed, let first = pages.first {
            let start = min(startAnchor.flatMap { book.location(of: $0) } ?? selected.location, book.storage.length)
            let end = min(endAnchor.flatMap { book.location(of: $0) } ?? NSMaxRange(selected), book.storage.length)
            first.setSelectedRange(NSRange(location: start, length: max(0, end - start)))
        }
        let firstPage = min(book.spread * 2, max(0, pages.count - 1))
        for (index, page) in pages.enumerated() {
            page.isHidden = !(firstPage..<firstPage + 2).contains(index)
            if !page.isHidden {
                page.frame = NSRect(x: CGFloat(index - firstPage) * (book.pageSize.width + CodexBookLayout.pageGap), y: 0,
                                    width: book.pageSize.width, height: book.pageSize.height)
            }
        }
        if navigationRevision != book.navigationRevision {
            navigationRevision = book.navigationRevision
            pages.first?.setSelectedRange(NSRange(location: 0, length: 0))
            if wasReading { activateReading() }
        } else if wasReading && !isReading(in: window) {
            activateReading()
        }
        let liveIDs = Set(book.codes.map(\.id))
        for id in Array(codeViews.keys) where !liveIDs.contains(id) {
            codeViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        codeViews.values.forEach { $0.isHidden = true }
        for code in book.codes {
            guard let pageIndex = book.ranges.firstIndex(where: { NSLocationInRange(code.range.location, $0) }),
                  pages.indices.contains(pageIndex), !pages[pageIndex].isHidden else { continue }
            let page = pages[pageIndex]
            guard let container = page.textContainer else { continue }
            let view: NSHostingView<AgentBookCodeBlock>
            if let existing = codeViews[code.id] {
                view = existing
                if view.rootView.code != code.text { view.rootView = AgentBookCodeBlock(code: code.text) }
            } else {
                view = NSHostingView(rootView: AgentBookCodeBlock(code: code.text))
                codeViews[code.id] = view
            }
            if view.superview !== page { page.addSubview(view) }
            let glyphs = book.manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
            let rect = book.manager.boundingRect(forGlyphRange: glyphs, in: container)
            view.frame = NSRect(x: rect.minX + page.textContainerOrigin.x,
                                y: rect.minY + page.textContainerOrigin.y,
                                width: code.size.width, height: code.size.height)
            view.isHidden = false
        }
    }
}

private final class AgentBookNativeTextView: NSTextView {
    weak var readingSurface: AgentBookTextSurface?

    override func selectAll(_ sender: Any?) {
        if let readingSurface { readingSurface.selectAll(sender) } else { super.selectAll(sender) }
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        var text = ""
        for value in selectedRanges {
            storage.enumerateAttributes(in: value.rangeValue) { attributes, range, _ in
                text += attributes[.codexFormulaSource] as? String
                    ?? attributes[.codexBookCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(text, forType: .string)
    }
}

// Keep the existing code-block chrome; AppKit owns text selection and horizontal scrolling.
private struct AgentBookCodeBlock: View {
    let code: String

    var body: some View {
        AgentBookCodeScroll(code: code)
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(CodexBookLayout.codeInset)
            }
    }
}

private struct AgentBookCodeScroll: NSViewRepresentable {
    let code: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = CodexBookLayout.codeFont
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: CodexBookLayout.codeInset, height: CodexBookLayout.codeInset)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != code {
            let selection = text.selectedRange()
            let origin = scroll.contentView.bounds.origin
            text.string = code
            let start = min(selection.location, (code as NSString).length)
            text.setSelectedRange(NSRange(location: start, length: min(selection.length, (code as NSString).length - start)))
            scroll.contentView.scroll(to: origin)
        }
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        text.frame.size = NSSize(width: ceil(used.width) + 2 * CodexBookLayout.codeInset, height: ceil(used.height) + 2 * CodexBookLayout.codeInset)
        assert(text.string == code, "Horizontal scrolling must not insert line breaks into the source")
    }
}

private struct AgentBookPageKeys: NSViewRepresentable {
    let focus: AgentBookFocus
    let isActive: () -> Bool
    let activateInput: () -> Void
    let move: (Int) -> Void

    func handle(_ event: NSEvent) -> Bool {
        guard isActive(), let window = event.window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty else { return false }
        guard focus.isReading(in: window),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (123, _), (_, "h"):
            focus.activateReading()
            move(-1)
        case (124, _), (_, "l"):
            focus.activateReading()
            move(1)
        case (49, _):
            activateInput()
        case (53, _):
            return true
        default:
            return false
        }
        return true
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor else { return event }
            return coordinator?.handle?(event) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
        var handle: ((NSEvent) -> Bool)?
    }
    private final class EventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
