import AppKit
import Combine
import SwiftUI

struct CodexBookView: View {
    @EnvironmentObject private var store: CodexStore
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @ObservedObject var book: CodexBookDocument
    let bookFocus: CodexBookFocus
    let featureActivity: RetainedPageActivity?
    var composerClearance: CGFloat = 64
    @State private var sessionActive = true
    @State private var featureActive = true

    private var visiblePages: Range<Int> { (book.spread * 2)..<min(book.pageCount, book.spread * 2 + 2) }
    private var canInteract: Bool { isActive && sessionActive && featureActive }

    var body: some View {
        VStack(spacing: 0) {
            CodexBookTextView(book: book, focus: bookFocus)
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
                        ForEach(book.headers.filter { visiblePages.contains($0.page) }) { header in
                            if let turn = store.turns.first(where: { $0.id == header.id }) {
                                CodexBookHeader(turn: turn, isActive: canInteract)
                                    .frame(width: header.frame.width, height: header.frame.height)
                                    .offset(x: pageX(header.page) + header.frame.minX, y: header.frame.minY)
                            }
                        }
                        if let contentBottom = book.contentBottoms.last {
                            CodexApprovalEntryView(request: store.requests.first(where: \.isApproval),
                                pageSize: book.pageSize, contentBottom: contentBottom, scale: 1,
                                isActive: canInteract && visiblePages.contains(book.pageCount - 1),
                                sessionActivity: activity, featureActivity: featureActivity,
                                decide: { store.approve($0, allow: $1) })
                                .offset(x: pageX(book.pageCount - 1))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            HStack {
                Button { move(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                }
                .disabled(book.spread == 0)
                .accessibilityLabel("前の見開き")
                Text("\(book.spread * 2 + 1)")
                Spacer()
                if book.spread * 2 + 1 < book.pageCount { Text("\(book.spread * 2 + 2)") }
                Button { move(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                }
                .disabled(book.spread == book.spreadCount - 1)
                .accessibilityLabel("次の見開き")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .buttonStyle(.plain).padding(.horizontal, 12)
            if let error = book.layoutError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .background(CodexPageKeys(focus: bookFocus, move: book.move))
        .padding(.bottom, composerClearance)
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { sessionActive = $0 }
        .onReceive(featureActivity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { featureActive = $0 }
    }

    private func pageX(_ page: Int) -> CGFloat {
        CGFloat(page - book.spread * 2) * (book.pageSize.width + CodexBookLayout.pageGap)
    }

    private func move(_ offset: Int) {
        bookFocus.activateReading()
        book.move(offset)
    }
}

private struct CodexBookHeader: View {
    let turn: CodexTurn
    let isActive: Bool
    @State private var showsHistory = false

    var body: some View {
        HStack {
            Text("Codex").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            ZStack {
                if turn.status == "inProgress" {
                    ProgressView().controlSize(.mini).accessibilityLabel("応答を生成中")
                }
            }
            .frame(width: 16, height: 16)
            Button("作業履歴", systemImage: "terminal") { showsHistory.toggle() }
                .font(.caption).buttonStyle(.plain)
                .popover(isPresented: $showsHistory) { CodexHistoryView(turns: [turn]) }
            Button("回答をコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.answers.map(\.displayMarkdown).joined(separator: "\n\n"), forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .onChange(of: isActive) { _, active in
            if !active { showsHistory = false }
        }
    }
}
