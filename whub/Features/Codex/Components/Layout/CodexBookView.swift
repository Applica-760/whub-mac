import AppKit
import Combine
import SwiftUI

struct CodexBookView: View {
    @EnvironmentObject private var store: CodexStore
    @ObservedObject var book: CodexBookPagination
    var composerClearance: CGFloat = 64
    @State private var selection = CodexBookSelection()
    @State private var readingFocus = TabPaneFocus()

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if let size = book.pageSize {
                    let width = size.width * 2 + 16
                    let scale = min(1, geometry.size.width / width, geometry.size.height / size.height)
                    HStack(spacing: 0) {
                        page(book.spread * 2, size: size)
                        Color.clear.frame(width: 16)
                        page(book.spread * 2 + 1, size: size)
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
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard book.pageSize == nil else { return }
                book.configure(viewport: size)
                book.update(store.turns)
            }
            .background(CodexSelectionSurface(selection: selection, bottomInset: composerClearance))
            .background(TabPaneFocusView(focus: readingFocus))
            .background(CodexPageKeys { event in
                guard let window = event.window, readingFocus.contains(window),
                      (window.firstResponder as? NSTextView)?.isEditable != true else { return false }
                book.move(event.keyCode == 123 ? -1 : 1)
                return true
            })
        }
        .environment(\.codexBookSelection, selection)
        .onChange(of: book.spread) { _, _ in selection.clear() }
        .onReceive(store.$turns.throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) {
            book.update($0)
        }
    }

    private func page(_ index: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if book.pages.indices.contains(index) {
                ForEach(book.pages[index].fragments) { fragment in
                    CodexMessageView(block: fragment.block, isUser: fragment.isUser, showsHeader: fragment.showsHeader, images: fragment.images, width: book.contentWidth, history: store.turns.filter { $0.id == fragment.turnID }) {
                        let answer = store.turns.first { $0.id == fragment.turnID }?.answers.map(\.text).joined(separator: "\n\n") ?? ""
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
        .overlay(alignment: index.isMultiple(of: 2) ? .bottomLeading : .bottomTrailing) {
            HStack(spacing: 0) {
                if index.isMultiple(of: 2) {
                    Button { book.move(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .disabled(book.spread == 0)
                    .accessibilityLabel("前の見開き")
                }
                Text("\(index + 1)")
                if !index.isMultiple(of: 2) {
                    Button { book.move(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .disabled(book.spread == book.spreadCount - 1)
                    .accessibilityLabel("次の見開き")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.bottom, 20)
        }
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
