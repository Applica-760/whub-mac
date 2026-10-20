import AppKit
import Combine
import SwiftUI
import WhubAgent

struct AgentBookExchangeView: View {
    @ObservedObject var store: AgentStore
    let agentName: String
    @Binding var spread: Int
    let pageCountChanged: (Int) -> Void
    let focus: AgentBookFocus
    var featureActivity: RetainedPageActivity? = nil
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @StateObject private var book: AgentBookPageLayout
    @State private var sessionActive = true
    @State private var featureActive = true

    init(store: AgentStore, agentName: String, spread: Binding<Int>,
         pageCountChanged: @escaping (Int) -> Void, focus: AgentBookFocus,
         featureActivity: RetainedPageActivity? = nil) {
        self.store = store
        self.agentName = agentName
        self._spread = spread
        self.pageCountChanged = pageCountChanged
        self.focus = focus
        self.featureActivity = featureActivity
        self._book = StateObject(wrappedValue: AgentBookPageLayout())
    }

    private var latestPageIsInteractive: Bool {
        book.selectedPage == book.pageCount - 1
    }
    private var canInteract: Bool { isActive && sessionActive && featureActive }
    private var approval: AgentRequest? {
        store.exchanges.last(where: { $0.status == .running })?.pendingRequests.first(where: \.isApproval)
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentBookTextView(book: book, focus: focus, header: { exchange in
                AnyView(
                    AgentBookExchangeHeader(exchange: exchange, agentName: agentName, isActive: canInteract)
                        .overlay(alignment: .bottom) {
                            Divider()
                        }
                )
            }, promptControl: { id in
                AnyView(
                    Button(book.isPromptExpanded(id) ? "折りたたむ" : "全文を表示",
                           systemImage: book.isPromptExpanded(id) ? "chevron.up" : "chevron.down") {
                        focus.activateReading()
                        book.togglePrompt(id)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .disabled(!canInteract)
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
            })
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        if let contentBottom = book.contentBottoms.last {
                            AgentBookApprovalEntryView(request: approval,
                                pageSize: book.pageSize, contentBottom: contentBottom, scale: 1,
                                isActive: canInteract && store.isConnected && latestPageIsInteractive,
                                sessionActivity: activity, featureActivity: featureActivity,
                                isResponding: approval.map { store.respondingRequestIDs.contains($0.id) } ?? false,
                                decide: { request, allow in
                                    guard canInteract else { return }
                                    Task { await store.respond(to: request.id, with: .approval(allow: allow)) }
                                })
                                .offset(x: book.pageOrigin(book.pageCount - 1, viewport: geometry.size).x,
                                        y: book.pageOrigin(book.pageCount - 1, viewport: geometry.size).y)
                                .opacity(latestPageIsInteractive ? 1 : 0)
                                .allowsHitTesting(latestPageIsInteractive)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            if let error = book.layoutError { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .background(AgentBookPageKeys(focus: focus, isActive: { canInteract },
                                      activateInput: focus.activateInput, move: focus.movePage, scroll: focus.scrollPage))
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
                .disabled(!isActive || exchange.history.isEmpty)
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

private struct AgentBookPageKeys: NSViewRepresentable {
    let focus: AgentBookFocus
    let isActive: () -> Bool
    let activateInput: () -> Void
    let move: (Int) -> Void
    let scroll: (Int) -> Void

    func handle(_ event: NSEvent) -> Bool {
        guard isActive(), let window = event.window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty else { return false }
        guard focus.isReading(in: window),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        switch (event.keyCode, event.charactersIgnoringModifiers) {
        case (123, _), (_, "h"):
            move(-1)
        case (124, _), (_, "l"):
            move(1)
        case (_, "j"):
            scroll(1)
        case (_, "k"):
            scroll(-1)
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
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow, window.attachedSheet == nil,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor else { return event }
            return coordinator?.process(event) == true ? nil : event
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
        private var consumedKeys: Set<UInt16> = []

        func process(_ event: NSEvent) -> Bool {
            if event.type == .keyUp {
                consumedKeys.remove(event.keyCode)
                return false
            }
            if !event.isARepeat { consumedKeys.remove(event.keyCode) }
            if handle?(event) == true {
                consumedKeys.insert(event.keyCode)
                return true
            }
            // A key held in Book mode must not repeat into the draft after Space.
            return event.isARepeat && consumedKeys.contains(event.keyCode)
        }
    }
    private final class EventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
