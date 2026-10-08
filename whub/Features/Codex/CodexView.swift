import AppKit
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexTabsStore
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: CodexStore.ID?

    var body: some View {
        VStack(spacing: 8) {
            TabBarContainer(
                ids: store.sessions.map(\.id),
                selection: store.selectedSessionID,
                select: { id in
                    tabFocus.activate()
                    store.select(id)
                },
                close: requestClose,
                canClose: { _ in store.sessions.count > 1 },
                move: store.move,
                isShortcutTarget: { pendingCloseID == nil && tabFocus.contains($0) }
            ) { id, isSelected, actions in
                if let index = store.sessions.firstIndex(where: { $0.id == id }) {
                    CodexConversationTab(
                        session: store.sessions[index], title: "Codex \(index + 1)",
                        isSelected: isSelected, canClose: store.sessions.count > 1, actions: actions
                    )
                }
            }
            CodexSessionView()
                .environmentObject(store.selectedSession)
                .id(store.selectedSessionID)
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .padding(.horizontal)
        .padding(.top, 8)
        .navigationTitle("Codex")
        .alert("実行中の会話があります", isPresented: Binding(
            get: { pendingCloseID != nil },
            set: { if !$0 { pendingCloseID = nil } }
        )) {
            Button("タブを閉じる", role: .destructive) {
                if let pendingCloseID { store.remove(pendingCloseID) }
                pendingCloseID = nil
            }
            Button("キャンセル", role: .cancel) { pendingCloseID = nil }
        } message: {
            Text("このタブを閉じると、実行中の作業が中断されます。")
        }
    }

    private func requestClose(_ id: CodexStore.ID) {
        guard store.sessions.count > 1,
              let session = store.sessions.first(where: { $0.id == id }) else { return }
        tabFocus.activate()
        if session.isBusy || !session.requests.isEmpty {
            pendingCloseID = id
        } else {
            store.remove(id)
        }
    }
}

private struct CodexConversationTab: View {
    @ObservedObject var session: CodexStore
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let actions: TabBarActions

    var body: some View {
        TabBar(
            title: title, icon: Image(systemName: "sparkles"),
            isSelected: isSelected, isCloseDisabled: !canClose,
            status: !session.requests.isEmpty ? (.orange, "回答・承認待ち")
                : session.isBusy ? (.blue, "作業中") : nil,
            action: actions.select, closeAction: actions.close
        )
    }
}

private struct CodexSessionView: View {
    @EnvironmentObject private var store: CodexStore
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(store.turns) { turn in
                            CodexMessageView(turn: turn).id(turn.id)
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .onChange(of: store.turns.count) { _, _ in
                    if let id = store.turns.last?.id { proxy.scrollTo(id, anchor: .top) }
                }

            }
            if !store.requests.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.requests) { request in
                            CodexInteractionRequestView(request: request) { store.answer(request, result: $0) }
                        }
                    }.padding(12)
                }
                .frame(maxHeight: 260)
                .background(.orange.opacity(0.08))
            }
            if let error = store.errorMessage {
                DisclosureGroup {
                    Text(error).textSelection(.enabled).font(.callout)
                } label: {
                    Label(String(error.prefix(160)), systemImage: "exclamationmark.triangle")
                        .lineLimit(2)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
            CodexInputView {
                if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
            }
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset() }
        } message: {
            Text("このタブの会話をクリアします。")
        }
    }

}
