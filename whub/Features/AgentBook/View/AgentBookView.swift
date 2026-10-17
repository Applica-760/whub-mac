import AppKit
import Combine
import SwiftUI

struct AgentBookView: View {
    @ObservedObject var store: AgentStore
    let sessions: [AgentStore]
    let completedSessionIDs: Set<AgentStore.ID>
    let notificationDates: [AgentStore.ID: Date]
    let select: (AgentStore.ID) -> Void
    let agentName: String
    let featureActivity: RetainedPageActivity?
    let skillStore: AgentSkillStore
    let historyStore: AgentHistoryStore
    let newConversation: () -> Void
    let resume: (AgentHistoryEntry) async -> Bool
    var isResuming = false
    var resumeError: String? = nil
    let changeKind: (AgentKind) -> Void
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @State private var bookFocus = AgentBookFocus()
    @State private var confirmsReset = false
    @State private var spread = 0
    @State private var pageCount = 1

    var body: some View {
        VStack(spacing: 0) {
            WidgetFrame {
                AgentBookExchangeView(
                    store: store, agentName: agentName, spread: $spread,
                    pageCountChanged: { pageCount = $0 }, focus: bookFocus,
                    featureActivity: featureActivity
                )
                // Reserve navigation space outside Exchange’s existing input inset.
                .padding(.bottom, AgentBookNavigationView.rowHeight)
                .overlay(alignment: .bottom) {
                    AgentBookNavigationView(
                        spread: $spread, pageCount: pageCount, isGenerating: store.isBusy,
                        focus: bookFocus, featureActivity: featureActivity
                    )
                }
                .overlay(alignment: .bottom) {
                    AgentBookInputView(
                        store: store, skillStore: skillStore, historyStore: historyStore,
                        focus: bookFocus, agentName: agentName,
                        newConversation: {
                            if store.exchanges.isEmpty { newConversation() }
                            else { confirmsReset = true }
                        },
                        resume: resume, isResuming: isResuming, resumeError: resumeError
                    )
                    .padding(.leading, 232)
                    .padding(.trailing, AgentBookOptionControlView.inputInset)
                }
                .overlay(alignment: .bottomLeading) {
                    AgentBookTabButton(
                        sessions: sessions, selection: store.id,
                        completedSessionIDs: completedSessionIDs,
                        notificationDates: notificationDates, select: select
                    )
                        .frame(width: 232, height: 36)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .bottomTrailing) {
                    AgentBookOptionControlView(store: store, changeKind: changeKind)
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
        .onChange(of: store.id) { _, _ in confirmsReset = false }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話", action: newConversation)
        } message: {
            Text("このタブの会話をクリアします。")
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
