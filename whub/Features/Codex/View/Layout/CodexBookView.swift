import AppKit
import Combine
import SwiftUI

struct CodexBookView: View {
    @EnvironmentObject private var store: CodexStore
    @ObservedObject var book: CodexBookPagination
    let focus: TabPaneFocus
    @State private var pendingApprovalIDs: Set<String> = []
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard book.pageSize == nil else { return }
                book.configure(viewport: size)
                book.update(store.turns)
            }
            .background(CodexSelectionSurface(selection: selection, bottomInset: composerClearance))
            .background(TabPaneFocusView(focus: readingFocus))
            .background(CodexPageKeys { event in
                if [36, 76, 53].contains(event.keyCode) {
                    guard let window = event.window, focus.contains(window),
                          let request = book.visibleApproval,
                          store.requests.contains(where: { $0.id == request.id }),
                          (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                    if let allow = CodexPageKeys.approvalDecision(keyCode: event.keyCode, isRepeat: event.isARepeat,
                                                                hasMarkedText: false) {
                        store.approve(request, allow: allow)
                    }
                    return true
                }
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
            let pending = $0.flatMap(\.approvals).filter { $0.outcome == nil }
            if let newRequest = pending.first(where: { !pendingApprovalIDs.contains($0.id) }) {
                book.revealApproval(newRequest.id)
            }
            pendingApprovalIDs = Set(pending.map(\.id))
        }
    }

    private func page(_ index: Int, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if book.pages.indices.contains(index) {
                ForEach(book.pages[index].fragments) { fragment in
                    Group {
                        if let request = fragment.approval {
                            CodexApprovalEntryView(request: request,
                                detailsExpanded: book.expandedApprovalDetailsIDs.contains(request.id),
                                toggleDetails: { book.toggleApprovalDetails(request.id, turns: store.turns) },
                                decide: { store.approve(request, allow: $0) })
                                .background(CodexSelectionExclusion())
                        } else {
                            CodexMessageView(block: fragment.block, isUser: fragment.isUser, showsHeader: fragment.showsHeader, images: fragment.images, width: book.contentWidth, history: store.turns.filter { $0.id == fragment.turnID }) {
                                let answer = store.turns.first { $0.id == fragment.turnID }?.answers.map(\.text).joined(separator: "\n\n") ?? ""
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(answer, forType: .string)
                            }
                        }
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

struct CodexPageKeys: NSViewRepresentable {
    static func approvalDecision(keyCode: UInt16, isRepeat: Bool, hasMarkedText: Bool) -> Bool? {
        guard !isRepeat, !hasMarkedText else { return nil }
        switch keyCode {
        case 36, 76: return true
        case 53: return false
        default: return nil
        }
    }

    let handle: (NSEvent) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
                  [123, 124, 36, 76, 53].contains(event.keyCode) else { return event }
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
