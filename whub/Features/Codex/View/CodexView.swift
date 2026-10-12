import AppKit
import Combine
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexTabsStore
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: CodexStore.ID?
    @State private var expandedDetails: [CodexStore.ID: Set<String>] = [:]
    @State private var books: [CodexStore.ID: CodexBookPagination] = [:]

    var body: some View {
        CodexSessionView(book: books[store.selectedSessionID], focus: tabFocus,
            expandedApprovalDetailsIDs: Binding(
                get: { expandedDetails[store.selectedSessionID] ?? [] },
                set: { expandedDetails[store.selectedSessionID] = $0 }
            )) {
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
            expandedDetails = expandedDetails.filter { ids.contains($0.key) }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .background(TabBarShortcuts(
            ids: store.sessions.map(\.id), selection: store.selectedSessionID,
            select: { id in tabFocus.activate(); store.select(id) }, close: requestClose,
            canClose: { _ in true },
            isShortcutTarget: { pendingCloseID == nil && tabFocus.contains($0) }
        ))
        .navigationTitle("AgentBook")
        .alert("このタブを閉じますか？", isPresented: Binding(
            get: { pendingCloseID != nil },
            set: { if !$0 { pendingCloseID = nil } }
        )) {
            Button("タブを閉じる", role: .destructive) {
                if let pendingCloseID { store.remove(pendingCloseID) }
                pendingCloseID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) { pendingCloseID = nil }
        } message: {
            Text("実行中の作業がある場合は中断されます。")
        }
    }

    private func requestClose(_ id: CodexStore.ID) {
        guard store.sessions.contains(where: { $0.id == id }) else { return }
        tabFocus.activate()
        pendingCloseID = id
    }
}

private struct CodexSessionView<Tabs: View>: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @EnvironmentObject private var store: CodexStore
    let book: CodexBookPagination?
    let focus: TabPaneFocus
    @Binding var expandedApprovalDetailsIDs: Set<String>
    @ViewBuilder let tabs: () -> Tabs
    @State private var confirmsReset = false
    @State private var composerClearance: CGFloat = 64
    @State private var bookFocus = CodexBookFocus()
    @State private var viewport = CGSize.zero
    @State private var needsUpdate = true
    @State private var pendingApprovalIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            WidgetFrame {
                ZStack {
                    if let book {
                        CodexBookView(book: book, focus: focus, bookFocus: bookFocus,
                            expandedApprovalDetailsIDs: expandedApprovalDetailsIDs,
                            toggleApprovalDetails: toggleApprovalDetails,
                            updateViewport: { viewport = $0; updateBook(store.turns) },
                            composerClearance: composerClearance)
                            .id(store.id)
                    } else {
                        Color.clear.frame(maxHeight: .infinity)
                    }
                }
                    .overlay(alignment: .bottom) {
                        CodexInputView(focus: bookFocus) {
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
        .onChange(of: store.id) { _, _ in
            confirmsReset = false
            pendingApprovalIDs = []
            updateBook(store.turns)
        }
        .onReceive(store.$turns.throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) {
            updateBook($0)
        }
        .onChange(of: isActive) { _, active in
            if active, needsUpdate { updateBook(store.turns) }
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset() }
        } message: {
            Text("このタブの会話をクリアします。")
        }
    }

    private func toggleApprovalDetails(_ id: String) {
        if !expandedApprovalDetailsIDs.insert(id).inserted { expandedApprovalDetailsIDs.remove(id) }
        updateBook(store.turns)
    }

    private func updateBook(_ turns: [CodexTurn]) {
        needsUpdate = true
        guard isActive, let book, viewport.width > 100, viewport.height > 100 else { return }
        expandedApprovalDetailsIDs.formIntersection(turns.flatMap(\.approvals).map(\.id))
        book.update(turns, viewport: viewport, expandedApprovalDetailsIDs: expandedApprovalDetailsIDs)
        let pending = turns.flatMap(\.approvals).filter { $0.outcome == nil }
        if let request = pending.first(where: { !pendingApprovalIDs.contains($0.id) }) {
            book.revealApproval(request.id)
        }
        pendingApprovalIDs = Set(pending.map(\.id))
        needsUpdate = false
    }

}
