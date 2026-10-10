import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexBookPagination: ObservableObject {
    typealias Block = CodexMarkdownResponseView.Block

    struct Fragment: Identifiable {
        let id: Int
        let turnID: UUID
        let block: Block
        var images: [CodexImageAttachment] = []
        var approval: CodexRequest? = nil
        let isUser: Bool
        let showsHeader: Bool
        let y: CGFloat
        let height: CGFloat
        let naturalHeight: CGFloat
        var scale: CGFloat { height / naturalHeight }
    }

    struct Page {
        var fragments: [Fragment] = []
        var usedHeight: CGFloat { fragments.last.map { $0.y + $0.height } ?? 0 }
    }

    @Published private(set) var pageSize: CGSize?
    @Published private(set) var pages = [Page()]
    @Published private(set) var spread = 0
    private(set) var expandedApprovalDetailsIDs: Set<String> = []
    private var approvalStates: [String] = []
    private var committedIDs: [UUID] = []
    private var committedPages = [Page()]
    private var measured: [Measurement: CGFloat] = [:]
    private var usedMeasurements: Set<Measurement> = []
    private let measuringView = NSHostingView(rootView: AnyView(EmptyView()))
    private let gap: CGFloat = 14

    var spreadCount: Int { max(1, (pages.count + 1) / 2) }
    var contentWidth: CGFloat { (pageSize?.width ?? 400) - 32 }
    // Keep the one-line composer (36pt), bottom inset (16pt) and a 12pt gap clear.
    var contentHeight: CGFloat { (pageSize?.height ?? 600) - 80 }

    func configure(viewport: CGSize) {
        guard pageSize == nil, viewport.width > 100, viewport.height > 100 else { return }
        pageSize = CGSize(width: max(280, floor((viewport.width - 16) / 2)), height: max(320, floor(viewport.height)))
    }

    func move(_ offset: Int) {
        spread = min(max(0, spread + offset), spreadCount - 1)
    }

    func toggleApprovalDetails(_ id: String, turns: [CodexTurn]) {
        if !expandedApprovalDetailsIDs.insert(id).inserted { expandedApprovalDetailsIDs.remove(id) }
        committedIDs = []
        committedPages = [Page()]
        update(turns)
    }

    func revealApproval(_ id: String) {
        if let page = pages.firstIndex(where: { $0.fragments.contains { $0.approval?.id == id } }) {
            spread = page / 2
        }
    }

    var visibleApproval: CodexRequest? {
        pages.dropFirst(spread * 2).prefix(2).flatMap(\.fragments)
            .compactMap(\.approval).first { $0.outcome == nil }
    }

    func update(_ turns: [CodexTurn]) {
        guard pageSize != nil else { return }
        let states = turns.flatMap(\.approvals).map { $0.id + ":" + ($0.outcome ?? "pending") }
        if states != approvalStates {
            approvalStates = states
            committedIDs = []
            committedPages = [Page()]
            expandedApprovalDetailsIDs.formIntersection(turns.flatMap(\.approvals).map(\.id))
        }
        if Array(turns.prefix(committedIDs.count).map(\.id)) != committedIDs || turns.isEmpty {
            committedIDs = []
            committedPages = [Page()]
            spread = 0
        }
        usedMeasurements.removeAll(keepingCapacity: true)
        var output = committedPages
        for turn in turns.dropFirst(committedIDs.count) {
            if !turn.prompt.isEmpty {
                append([Block(id: 0, kind: .paragraph, text: AttributedString(turn.prompt))],
                       turnID: turn.id, isUser: true, to: &output)
            }
            for image in turn.images {
                let last = output[output.count - 1].fragments.last
                let previous = last.flatMap { $0.isUser && $0.turnID == turn.id ? $0 : nil }
                let block = previous?.block ?? Block(id: 0, kind: .paragraph)
                let images = (previous?.images ?? []) + [image]
                let combinedHeight = height(block, isUser: true, header: false, images: images)
                if let previous, combinedHeight <= contentHeight {
                    output[output.count - 1].fragments.removeLast()
                    if !output[output.count - 1].fragments.isEmpty, remaining(output) < combinedHeight {
                        output.append(Page())
                    }
                    place(block, height: combinedHeight, naturalHeight: combinedHeight,
                          turnID: turn.id, isUser: true, header: previous.showsHeader, images: images, to: &output)
                } else {
                    let imageBlock = Block(id: 0, kind: .paragraph)
                    let naturalHeight = height(imageBlock, isUser: true, header: false, images: [image])
                    if !output[output.count - 1].fragments.isEmpty, remaining(output) < naturalHeight {
                        output.append(Page())
                    }
                    place(imageBlock, height: min(naturalHeight, contentHeight), naturalHeight: naturalHeight,
                          turnID: turn.id, isUser: true, header: false, images: [image], to: &output)
                }
            }
            for request in turn.approvals {
                measuringView.rootView = AnyView(CodexApprovalEntryView(request: request,
                    detailsExpanded: expandedApprovalDetailsIDs.contains(request.id), decide: { _ in })
                    .frame(width: contentWidth).fixedSize(horizontal: false, vertical: true))
                measuringView.frame.size = measuringView.fittingSize
                measuringView.layoutSubtreeIfNeeded()
                let height = min(contentHeight, max(1, ceil(measuringView.fittingSize.height)))
                if !output[output.count - 1].fragments.isEmpty, remaining(output) < height {
                    output.append(Page())
                }
                let last = output.count - 1
                let y = output[last].usedHeight + (output[last].fragments.isEmpty ? 0 : gap)
                output[last].fragments.append(Fragment(id: output[last].fragments.count, turnID: turn.id,
                    block: Block(id: 0, kind: .paragraph), approval: request, isUser: false,
                    showsHeader: false, y: y, height: height, naturalHeight: height))
            }
            if turn.answers.isEmpty {
                append([Block(id: 0, kind: .paragraph)], turnID: turn.id, isUser: false, to: &output)
            }
            for answer in turn.answers {
                append(CodexMarkdownResponseView(source: answer.text).blocks,
                       turnID: turn.id, isUser: false, to: &output)
            }
            // Only the unfinished response may reflow as Markdown delimiters arrive.
            if turn.status != "inProgress" {
                committedIDs.append(turn.id)
                committedPages = output
            }
        }
        measured = measured.filter { usedMeasurements.contains($0.key) }
        pages = output
        spread = min(spread, spreadCount - 1)
    }

    private struct Measurement: Hashable {
        let block: Block
        let isUser: Bool
        let header: Bool
        let imageIDs: [UUID]
    }

    private func height(_ block: Block, isUser: Bool, header: Bool, images: [CodexImageAttachment] = []) -> CGFloat {
        let key = Measurement(block: block, isUser: isUser, header: header, imageIDs: images.map(\.id))
        usedMeasurements.insert(key)
        if let cached = measured[key] { return cached }
        measuringView.rootView = AnyView(CodexMessageView(block: block, isUser: isUser, showsHeader: header, images: images, width: contentWidth)
            .frame(width: contentWidth).fixedSize(horizontal: false, vertical: true))
        measuringView.frame.size = measuringView.fittingSize
        measuringView.layoutSubtreeIfNeeded()
        let result = max(1, ceil(measuringView.fittingSize.height))
        measured[key] = result
        return result
    }

    private func append(_ blocks: [Block], turnID: UUID, isUser: Bool, to output: inout [Page]) {
        var header = true
        var followsHeading = false
        for index in blocks.indices {
            let block = blocks[index]
            if case .header = block.kind, index + 1 < blocks.count {
                let headingHeight = height(block, isUser: isUser, header: header)
                let nextHeight = height(blocks[index + 1], isUser: isUser, header: false)
                let needed = headingHeight + gap + min(nextHeight, max(44, contentHeight - headingHeight - gap))
                if !output[output.count - 1].fragments.isEmpty, remaining(output) < needed { output.append(Page()) }
            }
            append(block, turnID: turnID, isUser: isUser, header: &header, allowSplit: followsHeading, to: &output)
            if case .header = block.kind { followsHeading = true } else { followsHeading = false }
        }
    }

    private func remaining(_ output: [Page]) -> CGFloat {
        let page = output[output.count - 1]
        return contentHeight - page.usedHeight - (page.fragments.isEmpty ? 0 : gap)
    }

    private func append(_ original: Block, turnID: UUID, isUser: Bool, header: inout Bool,
                        allowSplit: Bool, to output: inout [Page]) {
        var block = original
        var splitHere = allowSplit
        while true {
            let naturalHeight = height(block, isUser: isUser, header: header)
            let available = remaining(output)
            if naturalHeight <= available {
                place(block, height: naturalHeight, naturalHeight: naturalHeight, turnID: turnID,
                      isUser: isUser, header: header, to: &output)
                header = false
                return
            }
            let occupied = !output[output.count - 1].fragments.isEmpty
            if occupied && (available < 44 || (naturalHeight <= contentHeight && !splitHere)) {
                output.append(Page())
                continue
            }
            if let (head, tail) = split(block, limit: available, measure: { self.height($0, isUser: isUser, header: header) }) {
                let fittedHeight = height(head, isUser: isUser, header: header)
                place(head, height: fittedHeight, naturalHeight: fittedHeight, turnID: turnID,
                      isUser: isUser, header: header, to: &output)
                header = false
                block = tail
                splitHere = false
                output.append(Page())
            } else {
                // An indivisible formula must remain visible even when taller than a page.
                place(block, height: available, naturalHeight: naturalHeight, turnID: turnID,
                      isUser: isUser, header: header, to: &output)
                header = false
                return
            }
        }
    }

    private func place(_ block: Block, height: CGFloat, naturalHeight: CGFloat, turnID: UUID,
                       isUser: Bool, header: Bool, images: [CodexImageAttachment] = [], to output: inout [Page]) {
        let last = output.count - 1
        let y = output[last].usedHeight + (output[last].fragments.isEmpty ? 0 : gap)
        output[last].fragments.append(Fragment(id: output[last].fragments.count, turnID: turnID, block: block, images: images,
            isUser: isUser, showsHeader: header, y: y, height: height, naturalHeight: naturalHeight))
    }

    private func split(_ block: Block, limit: CGFloat, measure: (Block) -> CGFloat) -> (Block, Block)? {
        if case .table = block.kind { return splitTable(block, limit: limit, measure: measure) }
        if !block.children.isEmpty {
            var count = 0
            for index in block.children.indices {
                var candidate = block
                candidate.children = Array(block.children.prefix(index + 1))
                if measure(candidate) > limit { break }
                count = index + 1
            }
            var head = block, tail = block
            if count > 0, count < block.children.count {
                head.children = Array(block.children.prefix(count))
                tail.children = Array(block.children.dropFirst(count))
            } else if count == 0, let first = block.children.first,
                      let (firstHead, firstTail) = split(first, limit: limit, measure: { child in
                          var candidate = block; candidate.children = [child]; return measure(candidate)
                      }) {
                head.children = [firstHead]
                tail.children = [firstTail] + block.children.dropFirst()
            } else { return nil }
            if case .listItem = tail.kind { tail.continued = true }
            return (head, tail)
        }
        return splitText(block, limit: limit, measure: measure)
    }

    private func splitText(_ block: Block, limit: CGFloat, measure: (Block) -> CGFloat) -> (Block, Block)? {
        let characters = block.text.characters
        let atomic = block.text.runs.filter { $0[CodexFormulaAttribute.self] != nil }.map(\.range)
        var boundaries = Array(characters.indices.dropFirst()).filter { index in
            !atomic.contains { $0.lowerBound < index && index < $0.upperBound }
        }
        if case .codeBlock = block.kind {
            boundaries = boundaries.filter { characters[characters.index(before: $0)] == "\n" }
        }
        var low = 0, high = boundaries.count
        while low < high {
            let mid = (low + high) / 2
            var candidate = block
            candidate.text = AttributedString(block.text[..<boundaries[mid]])
            if measure(candidate) <= limit { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        var boundary = boundaries[low - 1]
        let before = characters[characters.index(before: boundary)]
        let after = characters[boundary]
        if before.isASCII && after.isASCII && before.isLetter && after.isLetter,
           let wordBoundary = boundaries[..<low].last(where: { characters[characters.index(before: $0)].isWhitespace }) {
            boundary = wordBoundary
        }
        var head = block, tail = block
        head.text = AttributedString(block.text[..<boundary])
        tail.text = AttributedString(block.text[boundary...])
        return (head, tail)
    }

    private func splitTable(_ table: Block, limit: CGFloat, measure: (Block) -> CGFloat) -> (Block, Block)? {
        let headers = table.children.filter { $0.kind == .tableHeaderRow }
        let rows = table.children.filter { $0.kind != .tableHeaderRow }
        guard let first = rows.first else { return nil }
        var head = table, tail = table
        var count = 0
        for index in rows.indices {
            head.children = headers + rows.prefix(index + 1)
            if measure(head) > limit { break }
            count = index + 1
        }
        if count > 0, count < rows.count {
            head.children = headers + rows.prefix(count)
            tail.children = headers + rows.dropFirst(count)
            return (head, tail)
        }
        // Continue an oversized row without moving its cells into different columns.
        guard count == 0 else { return nil }
        var firstHead = first, firstTail = first
        firstHead.children = []; firstTail.children = []
        var didSplit = false
        for cell in first.children {
            func tableWith(_ candidate: Block) -> Block {
                var row = first; row.children = [candidate]
                var candidateTable = table; candidateTable.children = headers + [row]
                return candidateTable
            }
            if measure(tableWith(cell)) <= limit {
                firstHead.children.append(cell)
            } else if let (cellHead, cellTail) = splitText(cell, limit: limit, measure: { measure(tableWith($0)) }) {
                firstHead.children.append(cellHead); firstTail.children.append(cellTail); didSplit = true
            } else { return nil }
        }
        guard didSplit else { return nil }
        head.children = headers + [firstHead]
        tail.children = headers + [firstTail] + rows.dropFirst()
        return (head, tail)
    }
}
