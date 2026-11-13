import AppKit
import Combine
import SwiftUI
import WhubAgent

struct AgentBookResponseView: View {
    let request: AgentRequest
    var detailsExpanded = false
    var toggleDetails: () -> Void = {}
    var approvalDecision: ((Bool) -> Void)? = nil
    var isActive = true
    var isResponding = false
    var usesNativeKeyEquivalents = true
    let respond: (AgentResponse) -> Void
    @State private var answers: [String: String] = [:]
    @FocusState private var approvalFocused: Bool

    private var questions: [AgentQuestion] {
        if case .questions(let questions) = request.kind { return questions }
        return []
    }

    private var approval: AgentApprovalRequest? {
        if case .approval(let approval) = request.kind { return approval }
        return nil
    }

    private func decide(allow: Bool) {
        if let approvalDecision { approvalDecision(allow); return }
        respond(.approval(allow: allow))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(!request.isApproval ? "回答が必要です" : (request.outcome == nil ? "承認が必要です" : "実行リクエスト"), systemImage: "hand.raised.fill")
                .font(.headline)
            if !request.isApproval {
                ViewThatFits(in: .vertical) {
                    questionFields().fixedSize(horizontal: false, vertical: true)
                    ScrollView { questionFields() }
                }
            } else {
                ViewThatFits(in: .vertical) {
                    approvalDetails().fixedSize(horizontal: false, vertical: true)
                    ScrollView { approvalDetails() }
                }
                if let outcome = request.outcome {
                    Text(outcome.agentBookText).font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("拒否", role: .destructive) { decide(allow: false) }
                            .keyboardShortcut(usesNativeKeyEquivalents ? .cancelAction : nil)
                        Button("承認") { decide(allow: true) }
                            .buttonStyle(.borderedProminent)
                            .focused($approvalFocused)
                            .keyboardShortcut(usesNativeKeyEquivalents ? .defaultAction : nil)
                    }
                    .disabled(!isActive || isResponding)
                }
            }
        }
        .disabled(isResponding)
        .frame(maxWidth: Self.width(for: request), alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: request.id) {
            approvalFocused = isActive && request.isApproval && request.outcome == nil
        }
        .onChange(of: isActive) { _, active in
            approvalFocused = active && request.isApproval && request.outcome == nil
        }
    }

    static func width(for request: AgentRequest) -> CGFloat { request.isApproval ? 820 : 560 }

    private func questionFields() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions.indices, id: \.self) { index in
                let question = questions[index]
                let id = question.id
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(question.prompt)
                        if !question.options.isEmpty {
                            Text(question.isMultiSelect ? "複数選択" : "単一選択").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(question.options.indices, id: \.self) { optionIndex in
                        let option = question.options[optionIndex]
                        let selected = (answers[id] ?? "").components(separatedBy: ", ").contains(option.label)
                        Button(option.label) {
                            answers[id] = question.isMultiSelect ? toggle(option.label, in: answers[id] ?? "") : option.label
                        }
                        .buttonStyle(AgentBookOptionButtonStyle(isSelected: selected))
                        .help(option.description)
                    }
                    let binding = Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
                    Group {
                        if question.isSecret {
                            SecureField("回答", text: binding)
                        } else {
                            TextField("回答を入力", text: binding)
                        }
                    }
                    .textFieldStyle(.plain)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
                }
            }
            Button("回答を送信") {
                respond(.answers(answers))
            }
            .buttonStyle(.borderedProminent)
            .disabled(questions.contains { (answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ label: String, in answer: String) -> String {
        var labels = answer.components(separatedBy: ", ").filter { !$0.isEmpty }
        if let index = labels.firstIndex(of: label) { labels.remove(at: index) } else { labels.append(label) }
        return labels.joined(separator: ", ")
    }

    private func approvalDetails() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = approval?.reason { Text(reason) }
            if let command = approval?.command {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if let cwd = approval?.directory { Text(cwd).font(.caption).foregroundStyle(.secondary) }
            if let preview = approval?.changePreview {
                ScrollView {
                    Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }.frame(maxHeight: 120)
            }
            if let permissions = approval?.permissionsDescription {
                Text(permissions).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            DisclosureGroup("要求の詳細", isExpanded: Binding(get: { detailsExpanded }, set: { _ in toggleDetails() })) {
                Text(approval?.details ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct AgentBookOptionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        AgentBookOptionButton(configuration: configuration, isSelected: isSelected)
    }

    private struct AgentBookOptionButton: View {
        let configuration: Configuration
        let isSelected: Bool
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? AnyShapeStyle(.tint.opacity(configuration.isPressed ? 0.25 : 0.15))
                            : AnyShapeStyle(configuration.isPressed || isHovered ? .quaternary : .quinary), in: shape)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }
    }
}

struct AgentBookRequestEntryView: View {
    let request: AgentRequest?
    let pageSize: CGSize
    let contentBottom: CGFloat
    let scale: CGFloat
    var isActive = true
    var sessionActivity: RetainedPageActivity? = nil
    var featureActivity: RetainedPageActivity? = nil
    var isResponding = false
    let respond: (AgentRequest, AgentResponse) -> Void
    @State private var showsDetails = false

    private var canRespond: Bool {
        !isResponding && isActive && sessionActivity?.isActive.value != false && featureActivity?.isActive.value != false
    }

    private func respond(_ request: AgentRequest, with response: AgentResponse) {
        guard canRespond else { return }
        respond(request, response)
    }

    var body: some View {
        let anchorY = min(contentBottom, pageSize.height - 16)
        let above = anchorY > pageSize.height / 2
        let availableHeight = (above ? anchorY : pageSize.height - anchorY) * scale - 24
        Group {
            if let request {
                AgentBookResponseView(request: request, detailsExpanded: showsDetails,
                    toggleDetails: { showsDetails.toggle() },
                    approvalDecision: { respond(request, with: .approval(allow: $0)) },
                    isActive: canRespond, isResponding: isResponding, usesNativeKeyEquivalents: false) { respond(request, with: $0) }
                    .frame(width: max(1, min(AgentBookResponseView.width(for: request) + 32, (pageSize.width - 32) * scale)))
                    .frame(maxHeight: max(1, availableHeight))
                    .background(AgentBookApprovalKeys(isActive: { canRespond && request.isApproval }) {
                        respond(request, with: .approval(allow: $0))
                    })
                    .padding(.top, above ? 0 : anchorY + 12)
                    .padding(.bottom, above ? pageSize.height - anchorY + 12 : 0)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: above ? .bottom : .top)
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(isActive)
        .accessibilityHidden(!isActive)
        .onChange(of: request?.id) { _, _ in showsDetails = false }
    }
}

private struct AgentBookApprovalKeys: NSViewRepresentable {
    static func approvalDecision(keyCode: UInt16, isRepeat: Bool, hasMarkedText: Bool) -> Bool? {
        guard !isRepeat, !hasMarkedText else { return nil }
        switch keyCode {
        case 36, 76: return true
        case 53: return false
        default: return nil
        }
    }

    var isActive: () -> Bool = { true }
    let approve: (Bool) -> Void

    func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard isActive(), event.window === window, window.attachedSheet == nil,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty,
              [36, 76, 53].contains(event.keyCode),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        if let allow = Self.approvalDecision(keyCode: event.keyCode, isRepeat: event.isARepeat, hasMarkedText: false) {
            approve(allow)
        }
        return true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = EventView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let window = view.window, window.isKeyWindow,
                  !view.isHiddenOrHasHiddenAncestor else { return event }
            return coordinator?.handle?(event, window) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
    final class Coordinator {
        var monitor: Any?
        var handle: ((NSEvent, NSWindow) -> Bool)?
    }
    final class EventView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
