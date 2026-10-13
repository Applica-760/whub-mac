import AppKit
import SwiftUI

struct CodexBookView: View {
    @EnvironmentObject private var store: CodexStore
    @ObservedObject var book: CodexBookPagination
    let bookFocus: CodexBookFocus
    let updateViewport: (CGSize) -> Void
    var composerClearance: CGFloat = 64
    @State private var selection = CodexBookSelection()

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if let size = book.pageSize {
                    let width = size.width * 2 + 16
                    let scale = min(1, geometry.size.width / width, geometry.size.height / size.height)
                    HStack(spacing: 0) {
                        page(book.spread * 2, size: size, scale: scale)
                        Color.clear.frame(width: 16)
                        page(book.spread * 2 + 1, size: size, scale: scale)
                    }
                    .frame(width: width, height: size.height)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .top) {
                        Rectangle().fill(.secondary.opacity(0.18))
                            .frame(width: 1, height: max(0, geometry.size.height - composerClearance - 20))
                            .padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { updateViewport($0) }
            .background(CodexSelectionSurface(selection: selection, focus: bookFocus, bottomInset: composerClearance))
            .background(CodexPageKeys(focus: bookFocus, move: book.move))
        }
        .environment(\.codexBookSelection, selection)
        .onChange(of: book.spread) { _, _ in selection.clear() }
        .onChange(of: book.pageSize) { _, _ in selection.clear() }
    }

    private func move(_ offset: Int) {
        bookFocus.activateReading()
        book.move(offset)
    }

    private func page(_ index: Int, size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if book.pages.indices.contains(index) {
                ForEach(book.pages[index].fragments) { fragment in
                    CodexMessageView(block: fragment.block, isUser: fragment.isUser, showsHeader: fragment.showsHeader, images: fragment.images, width: book.contentWidth, history: store.turns.filter { $0.id == fragment.turnID }) {
                        let answer = store.turns.first { $0.id == fragment.turnID }?.answers.map(\.displayMarkdown).joined(separator: "\n\n") ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                    .environment(\.codexSelectionOrder, [index, fragment.id])
                    .environment(\.codexSelectionSource, fragment.turnID.uuidString)
                    .frame(width: book.contentWidth, height: fragment.naturalHeight, alignment: .topLeading)
                    .scaleEffect(fragment.scale, anchor: .topLeading)
                    .offset(x: 16, y: 16 + fragment.y)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if index == book.pages.count - 1 {
                CodexApprovalEntryView(request: store.requests.first(where: \.isApproval),
                    pageSize: size, contentBottom: 16 + book.pages[index].usedHeight, scale: scale,
                    decide: { store.approve($0, allow: $1) })
            }
        }
        .overlay(alignment: index.isMultiple(of: 2) ? .bottomLeading : .bottomTrailing) {
            HStack(spacing: 0) {
                if index.isMultiple(of: 2), book.spread > 0 {
                    Button { move(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .accessibilityLabel("前の見開き")
                } else if index.isMultiple(of: 2) {
                    Color.clear.frame(width: 28, height: 28).allowsHitTesting(false)
                }
                Text("\(index + 1)")
                if !index.isMultiple(of: 2), book.spread < book.spreadCount - 1 {
                    Button { move(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .accessibilityLabel("次の見開き")
                } else if !index.isMultiple(of: 2) {
                    Color.clear.frame(width: 28, height: 28).allowsHitTesting(false)
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .fontWeight((index.isMultiple(of: 2) ? book.spread > 0 : book.spread < book.spreadCount - 1) ? .bold : .regular)
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1)ページ")
    }
}
