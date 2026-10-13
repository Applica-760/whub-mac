import Combine
import SwiftUI

struct CodexInteractionRequestsView: View {
    let requests: [CodexRequest]
    let respond: (CodexRequest, [String: Any]) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(requests) { request in
                    CodexInteractionRequestView(request: request) { respond(request, $0) }
                }
            }.padding(12)
        }
        .frame(maxHeight: 260)
        .background(.orange.opacity(0.08))
    }
}

struct CodexInteractionRequestView: View {
    let request: CodexRequest
    var detailsExpanded = false
    var toggleDetails: () -> Void = {}
    var approvalDecision: ((Bool) -> Void)? = nil
    var isActive = true
    var usesNativeKeyEquivalents = true
    let respond: ([String: Any]) -> Void
    @State private var answers: [String: String] = [:]
    @FocusState private var approvalFocused: Bool

    private var questions: [[String: Any]] { request.params["questions"] as? [[String: Any]] ?? [] }

    private func decide(allow: Bool) {
        if let approvalDecision { approvalDecision(allow); return }
        if request.method == "item/permissions/requestApproval" {
            respond(["permissions": allow ? (request.params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"])
        } else {
            respond(["decision": allow ? "accept" : "decline"])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.method == "item/tool/requestUserInput" ? "回答が必要です" : (request.outcome == nil ? "承認が必要です" : "実行リクエスト"), systemImage: "hand.raised.fill")
                .font(.headline)
            if request.method == "item/tool/requestUserInput" {
                ForEach(questions.indices, id: \.self) { index in
                    let question = questions[index]
                    let id = question["id"] as? String ?? "\(index)"
                    Text(question["question"] as? String ?? "")
                    ForEach((question["options"] as? [[String: String]] ?? []).indices, id: \.self) { optionIndex in
                        let option = (question["options"] as? [[String: String]] ?? [])[optionIndex]
                        Button {
                            answers[id] = option["label"] ?? ""
                        } label: {
                            VStack(alignment: .leading) {
                                Text(option["label"] ?? "")
                                Text(option["description"] ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let binding = Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
                    if question["isSecret"] as? Bool == true {
                        SecureField("回答", text: binding)
                    } else {
                        TextField("回答を入力", text: binding)
                    }
                }
                Button("回答を送信") {
                    respond(["answers": answers.mapValues { ["answers": [$0]] }])
                }
                .disabled(questions.contains { (answers[$0["id"] as? String ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else {
                ViewThatFits(in: .vertical) {
                    approvalDetails().fixedSize(horizontal: false, vertical: true)
                    ScrollView { approvalDetails() }
                }
                if let outcome = request.outcome {
                    Text(outcome.displayText).font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("拒否", role: .destructive) { decide(allow: false) }
                            .keyboardShortcut(usesNativeKeyEquivalents ? .cancelAction : nil)
                        Button("承認") { decide(allow: true) }
                            .buttonStyle(.borderedProminent)
                            .focused($approvalFocused)
                            .keyboardShortcut(usesNativeKeyEquivalents ? .defaultAction : nil)
                    }
                    .disabled(!isActive)
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .task(id: request.id) {
            approvalFocused = isActive && request.isApproval && request.outcome == nil
        }
        .onChange(of: isActive) { _, active in
            approvalFocused = active && request.isApproval && request.outcome == nil
        }
    }

    private var changePreview: String? {
        if let changes = request.params["changes"] as? [[String: Any]] { return CodexItem.changePreview(changes) }
        return request.params["changePreview"] as? String
    }

    private func approvalDetails() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = request.params["reason"] as? String { Text(reason) }
            if let command = request.params["command"] as? String {
                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            if let cwd = request.params["cwd"] as? String { Text(cwd).font(.caption).foregroundStyle(.secondary) }
            if let preview = changePreview {
                ScrollView {
                    Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }.frame(maxHeight: 120)
            }
            if let permissions = request.params["permissions"] as? [String: Any] {
                Text(CodexJSON.pretty(permissions)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            DisclosureGroup("要求の詳細", isExpanded: Binding(get: { detailsExpanded }, set: { _ in toggleDetails() })) {
                Text(CodexJSON.pretty(request.params)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct CodexApprovalEntryView: View {
    let request: CodexRequest?
    let pageSize: CGSize
    let contentBottom: CGFloat
    let scale: CGFloat
    var isActive = true
    var sessionActivity: RetainedPageActivity? = nil
    var featureActivity: RetainedPageActivity? = nil
    let decide: (CodexRequest, Bool) -> Void
    @State private var showsDetails = false

    private var canRespond: Bool {
        isActive && sessionActivity?.isActive.value != false && featureActivity?.isActive.value != false
    }

    private func respond(_ request: CodexRequest, allow: Bool) {
        guard canRespond else { return }
        decide(request, allow)
    }

    var body: some View {
        let anchorY = min(contentBottom, pageSize.height - 16)
        let above = anchorY > pageSize.height / 2
        let availableHeight = (above ? anchorY : pageSize.height - anchorY) * scale - 24
        Group {
            if let request {
                CodexInteractionRequestView(request: request, detailsExpanded: showsDetails,
                    toggleDetails: { showsDetails.toggle() },
                    approvalDecision: { respond(request, allow: $0) },
                    isActive: canRespond, usesNativeKeyEquivalents: false) { _ in }
                    .frame(width: max(1, min(820 + 32, (pageSize.width - 32) * scale)))
                    .frame(maxHeight: max(1, availableHeight))
                    .background(CodexApprovalKeys(isActive: { canRespond }) { respond(request, allow: $0) })
                    .shadow(radius: 8, y: 3)
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
