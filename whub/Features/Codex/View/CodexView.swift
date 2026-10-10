import AppKit
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexTabsStore
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: CodexStore.ID?
    @State private var books: [CodexStore.ID: CodexBookPagination] = [:]

    var body: some View {
        CodexSessionView(book: books[store.selectedSessionID], focus: tabFocus) {
            CodexTabBar(sessions: store.sessions, selection: store.selectedSessionID,
                        completedSessionIDs: store.completedSessionIDs) { id in
                tabFocus.activate()
                store.select(id)
            }
        }
        .environmentObject(store.selectedSession)
        .task(id: store.selectedSessionID) {
            if books[store.selectedSessionID] == nil { books[store.selectedSessionID] = CodexBookPagination() }
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            books = books.filter { ids.contains($0.key) }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .background(TabBarShortcuts(
            ids: store.sessions.map(\.id), selection: store.selectedSessionID,
            select: { id in tabFocus.activate(); store.select(id) }, close: requestClose,
            canClose: { _ in store.sessions.count > 1 },
            isShortcutTarget: { pendingCloseID == nil && tabFocus.contains($0) }
        ))
        .padding(.horizontal)
        .padding(.top, 8)
        .navigationTitle("AgentBook")
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

private struct CodexSessionView<Tabs: View>: View {
    @EnvironmentObject private var store: CodexStore
    let book: CodexBookPagination?
    let focus: TabPaneFocus
    @ViewBuilder let tabs: () -> Tabs
    @State private var confirmsReset = false
    @State private var composerClearance: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let book {
                    CodexBookView(book: book, focus: focus, composerClearance: composerClearance)
                        .id(store.id)
                } else {
                    Color.clear.frame(maxHeight: .infinity)
                }
            }
                .overlay(alignment: .bottom) {
                    CodexInputView {
                        if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
                    }
                    .id(store.id)
                    .padding(.horizontal, 212)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        composerClearance = $0 + 4
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    tabs()
                        .frame(width: 156, height: 36)
                        .padding(.leading, 56)
                        .padding(.bottom, 16)
                }
            if store.requests.contains(where: { !$0.isApproval }) {
                CodexInteractionRequestsView(requests: store.requests.filter { !$0.isApproval }) { request, result in
                    store.answer(request, result: result)
                }
            }
            if let error = store.errorMessage {
                CodexErrorView(message: error)
            }
        }
        .onChange(of: store.id) { _, _ in confirmsReset = false }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset() }
        } message: {
            Text("このタブの会話をクリアします。")
        }
    }

}
