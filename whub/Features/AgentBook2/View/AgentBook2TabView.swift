import AppKit
import Combine
import SwiftUI
import SwiftData
import WhubAgent
import WhubCore

struct AgentBook2TabView: View {
    @ObservedObject var bookStore: AgentBook2Store
    @ObservedObject var store: AgentStore
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var servers: RemoteServerStore
    let tab: AgentBook2TabStore
    let featureActivity: RetainedPageActivity?
    let select: (AgentStore.ID) -> Void
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @State private var bookFocus = AgentBook2Focus()
    @State private var confirmsReset = false
    @State private var spread = 0
    @State private var pageCount = 1

    var body: some View {
        VStack(spacing: 0) {
            WidgetFrame {
                AgentBook2ExchangeView(
                    store: store, agentName: agentName, spread: $spread,
                    pageCountChanged: { pageCount = $0 }, focus: bookFocus,
                    featureActivity: featureActivity
                )
                // Reserve navigation space outside Exchange’s existing input inset.
                .padding(.bottom, AgentBook2NavigationView.rowHeight)
                .overlay(alignment: .bottom) {
                    AgentBook2NavigationView(
                        spread: $spread, pageCount: pageCount, isGenerating: store.isBusy,
                        focus: bookFocus, featureActivity: featureActivity
                    )
                }
                .overlay(alignment: .bottom) {
                    AgentBook2InputView(
                        store: store, skillStore: tab.skillStore, historyStore: tab.historyStore,
                        focus: bookFocus, agentName: agentName,
                        newConversation: {
                            if store.exchanges.isEmpty { newConversation() }
                            else { confirmsReset = true }
                        },
                        resume: { await bookStore.resume($0, replacing: tab.id) },
                        isResuming: bookStore.isResuming, resumeError: bookStore.resumeError
                    )
                    .padding(.leading, 232)
                    .padding(.trailing, AgentBook2OptionControlView.inputInset)
                }
                .overlay(alignment: .bottomLeading) {
                    AgentBook2TabButton(
                        tabs: bookStore.tabs, selection: tab.id,
                        completedSessionIDs: bookStore.completedTabIDs,
                        notificationDates: bookStore.notificationDates,
                        select: select
                    )
                        .frame(width: 232, height: 36)
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .bottomTrailing) {
                    AgentBook2OptionControlView(
                        store: store, canChangeKind: bookStore.canChangeKind(in: tab.id),
                        changeKind: { bookStore.changeKind($0, in: tab.id) },
                        hosts: bookStore.hosts, hostsError: bookStore.hostsError,
                        canChangeHost: bookStore.canChangeHost(in: tab.id),
                        changeHost: { host in
                            guard isHostConnected(host) else { return }
                            bookStore.changeHost(host, in: tab.id, servers: servers)
                        },
                        isHostConnected: isHostConnected
                    )
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .topTrailing) {
                    if let error = store.errorMessage {
                        AgentBook2ErrorView(message: error)
                            .padding(12)
                    }
                }
            }
            if !pendingQuestions.isEmpty {
                AgentBook2ResponsesView(requests: pendingQuestions, respondingRequestIDs: store.respondingRequestIDs,
                                       isActive: store.isConnected && isActive, respond: respond)
            }
        }
        .task(id: isActive) {
            if isActive {
                bookStore.loadHosts()
                await bookStore.connect(tab.id)
            }
        }
        .onChange(of: store.id) { _, _ in confirmsReset = false }
        .onChange(of: connections.states) { previous, states in
            guard store.target.keepsExecutionOnDisconnect,
                  let hostID = store.target.host?.persistentModelID,
                  previous[hostID] != .connected, states[hostID] == .connected else { return }
            Task { await bookStore.connect(tab.id, reconnect: true) }
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話", action: newConversation)
        } message: {
            Text("このタブの会話をクリアします。")
        }
    }

    private var agentName: String { store.agentKind.displayName }

    private func isHostConnected(_ host: WhubCore.Host) -> Bool {
        switch host {
        case let remote as RemoteHost: connections.connection(for: remote) != nil
        case is LocalHost: true
        default: false
        }
    }

    private func newConversation() {
        bookStore.newConversation(in: tab.id)
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

private struct AgentBook2ErrorView: View {
    let message: String

    var body: some View {
        DisclosureGroup {
            ScrollView {
                Text(message).textSelection(.enabled).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Label(String(message.prefix(160)), systemImage: "exclamationmark.triangle")
                .lineLimit(2)
        }
        .foregroundStyle(.red)
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 420)
    }
}
