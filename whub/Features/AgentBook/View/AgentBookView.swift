import AppKit
import Combine
import SwiftUI

struct AgentBookView<Book: View, Tabs: View, ModelControls: View, Candidates: View>: View {
    @ObservedObject var store: AgentStore
    let featureActivity: RetainedPageActivity?
    let submit: () -> Void
    let handleCandidateKey: (NSEvent, Binding<NSRange>) -> Bool
    @ViewBuilder let book: ([AgentExchange]) -> Book
    @ViewBuilder let tabs: () -> Tabs
    @ViewBuilder let modelControls: () -> ModelControls
    @ViewBuilder let candidates: (Binding<NSRange>) -> Candidates
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    let bookFocus: CodexBookFocus

    var body: some View {
        VStack(spacing: 0) {
            WidgetFrame {
                book(store.exchanges)
                .overlay(alignment: .bottom) {
                    AgentBookInputView(
                        input: $store.draft, focus: bookFocus,
                        isBusy: store.isBusy, isStopping: store.isStopping,
                        send: submit, interrupt: { Task { await store.interrupt() } },
                        handleCandidateKey: handleCandidateKey, candidates: candidates
                    )
                    .padding(.horizontal, 232)
                }
                .overlay(alignment: .bottomLeading) {
                    tabs()
                        .frame(width: 232, height: 36)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .bottomTrailing) {
                    modelControls()
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .topTrailing) {
                    if let error = store.errorMessage {
                        CodexErrorView(message: error)
                            .padding(12)
                    }
                }
            }
            if !pendingQuestions.isEmpty {
                AgentBookResponsesView(requests: pendingQuestions, respondingRequestIDs: store.respondingRequestIDs,
                                       isActive: store.isConnected && isActive, respond: respond)
            }
        }
    }

    private var pendingQuestions: [AgentRequest] {
        store.exchanges.last(where: { $0.status == .running })?.pendingRequests.filter { !$0.isApproval } ?? []
    }

    private func respond(_ request: AgentRequest, _ response: AgentResponse) {
        guard isActive, store.isConnected, activity?.isActive.value != false,
              featureActivity?.isActive.value != false else { return }
        Task { await store.respond(to: request.id, with: response) }
    }

}
