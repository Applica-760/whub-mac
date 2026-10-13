import AppKit
import Combine
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexTabsStore
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: CodexStore.ID?
    @Environment(\.retainedPageActivity) private var featureActivity

    var body: some View {
        RetainedPageContainer(selection: store.selectedSessionID, availablePages: store.sessions.map(\.id)) { id in
            if let session = store.sessions.first(where: { $0.id == id }) {
                CodexSessionView(featureActivity: featureActivity) {
                    CodexTabBar(sessions: store.sessions, selection: store.selectedSessionID,
                                completedSessionIDs: store.completedSessionIDs) { id in
                        tabFocus.activate()
                        store.select(id)
                    }
                }
                .environmentObject(session)
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .background(TabBarShortcuts(
            ids: store.sessions.map(\.id), selection: store.selectedSessionID,
            select: { id in tabFocus.activate(); store.select(id) }, close: requestClose,
            canClose: { _ in true },
            isShortcutTarget: { _ in pendingCloseID == nil },
            handlesNumberKeys: false
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
    let featureActivity: RetainedPageActivity?
    @Environment(\.retainedPageActivity) private var activity
    @StateObject private var book = CodexBookPagination()
    @ViewBuilder let tabs: () -> Tabs
    @State private var confirmsReset = false
    @State private var composerClearance: CGFloat = 64
    @State private var bookFocus = CodexBookFocus()
    @State private var viewport = CGSize.zero
    @State private var needsLatestPage = true

    var body: some View {
        VStack(spacing: 0) {
            WidgetFrame {
                ZStack {
                    CodexBookView(book: book, bookFocus: bookFocus,
                        updateViewport: { viewport = $0; updateBook(store.turns) },
                        composerClearance: composerClearance)
                }
                    .overlay(alignment: .bottom) {
                        CodexInputView(commands: store.commands, focus: bookFocus) {
                            if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
                        }
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
            needsLatestPage = true
            updateBook(store.turns)
        }
        .onReceive(store.$turns.throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)) {
            updateBook($0)
        }
        .onChange(of: isActive) { _, active in
            if active {
                needsLatestPage = true
                updateBook(store.turns)
            }
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset() }
        } message: {
            Text("このタブの会話をクリアします。")
        }
    }

    private func updateBook(_ turns: [CodexTurn]) {
        guard isActive, activity?.isActive.value != false, featureActivity?.isActive.value != false,
              viewport.width > 100, viewport.height > 100 else { return }
        book.update(turns, viewport: viewport)
        if needsLatestPage {
            book.move(book.spreadCount - 1 - book.spread)
            assert(book.spread == book.spreadCount - 1)
            needsLatestPage = false
        }
    }

}
