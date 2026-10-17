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
    @StateObject private var book = AgentBookPageLayout()
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
                            if let exchange = book.exchange(header.id) {
                                AgentBookExchangeHeader(exchange: exchange, agentName: agentName, isActive: canInteract,
                                    isHistoryExpanded: book.isHistoryExpanded(header.id),
                                    toggleHistory: { book.toggleHistory(header.id) })
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
        CGFloat(page - book.spread * 2) * (book.pageSize.width + AgentBookPageStyle.pageGap)
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
    let isHistoryExpanded: Bool
    let toggleHistory: () -> Void

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
            Button("作業履歴", systemImage: isHistoryExpanded ? "chevron.down" : "chevron.right", action: toggleHistory)
                .font(.caption).buttonStyle(.plain)
                .disabled(!isActive || exchange.history.isEmpty)
            Button("回答をコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.answers.map(\.agentBookMarkdown).joined(separator: "\n\n"), forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }
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
