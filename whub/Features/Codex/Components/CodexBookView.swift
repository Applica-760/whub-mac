import AppKit
import Combine
import SwiftUI

struct CodexBookView: View {
    @EnvironmentObject private var store: CodexStore
    @ObservedObject var book: CodexBookPagination
    @State private var showsHistory = false
    @State private var readingFocus = TabPaneFocus()

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if let size = book.pageSize {
                    let width = size.width * 2 + 24
                    let scale = min(1, geometry.size.width / width, geometry.size.height / size.height)
                    HStack(spacing: 0) {
                        page(book.spread * 2, size: size)
                        Rectangle().fill(.secondary.opacity(0.18)).frame(width: 1)
                            .padding(.horizontal, 11.5).padding(.vertical, 20)
                        page(book.spread * 2 + 1, size: size)
                    }
                    .frame(width: width, height: size.height)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard book.pageSize == nil else { return }
                book.configure(viewport: size)
                book.update(store.turns)
            }
            .background(TabPaneFocusView(focus: readingFocus))
            .background(CodexPageKeys { event in
                guard let window = event.window, readingFocus.contains(window),
                      (window.firstResponder as? NSTextView)?.isEditable != true else { return false }
                book.move(event.keyCode == 123 ? -1 : 1)
                return true
            })

            HStack(spacing: 16) {
                Button("前の見開き", systemImage: "chevron.left") { book.move(-1) }
                    .labelStyle(.iconOnly).disabled(book.spread == 0)
                Text("\(book.spread * 2 + 1)–\(book.spread * 2 + 2) / \(book.spreadCount * 2)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("次の見開き", systemImage: "chevron.right") { book.move(1) }
                    .labelStyle(.iconOnly).disabled(book.spread == book.spreadCount - 1)
                Button("最新へ", systemImage: "arrow.right.to.line") { book.showLatest() }
                    .disabled(book.spread == book.spreadCount - 1)
                Divider().frame(height: 16)
                Button("作業履歴", systemImage: "terminal") { showsHistory.toggle() }
                    .popover(isPresented: $showsHistory) { CodexHistoryView(turns: store.turns) }
                if store.isBusy { ProgressView().controlSize(.small).accessibilityLabel("応答を生成中") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .onReceive(store.$turns.throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) {
            book.update($0)
        }
    }

    private func page(_ index: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(.background)
            if book.pages.indices.contains(index) {
                ForEach(book.pages[index].fragments) { fragment in
                    CodexMessageView(block: fragment.block, isUser: fragment.isUser, showsHeader: fragment.showsHeader, width: book.contentWidth) {
                        let answer = store.turns.first { $0.id == fragment.turnID }?.answers.map(\.text).joined(separator: "\n\n") ?? ""
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                    .frame(width: book.contentWidth, height: fragment.naturalHeight, alignment: .topLeading)
                    .scaleEffect(fragment.scale, anchor: .topLeading)
                    .offset(x: 24, y: 24 + fragment.y)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottom) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).padding(.bottom, 12)
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(index + 1)ページ")
    }
}

private struct CodexPageKeys: NSViewRepresentable {
    let handle: (NSEvent) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
                  [123, 124].contains(event.keyCode) else { return event }
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
