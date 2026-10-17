import AppKit
import Combine
import SwiftUI

struct AgentBookView: View {
    @ObservedObject var store: AgentBookStore
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: AgentBookTabStore.ID?
    @Environment(\.retainedPageActivity) private var featureActivity

    var body: some View {
        RetainedPageContainer(selection: store.selectedTabID, availablePages: store.tabs.map(\.id)) { id in
            if let tab = store.tabs.first(where: { $0.id == id }) {
                AgentBookTabView(bookStore: store, store: tab.store, tab: tab,
                                 featureActivity: featureActivity, select: select)
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .background(TabBarShortcuts(
            ids: store.tabs.map(\.id), selection: store.selectedTabID,
            select: select, close: requestClose,
            canClose: { _ in true },
            isShortcutTarget: { _ in pendingCloseID == nil },
            handlesNumberKeys: false
        ))
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

    private func select(_ id: AgentBookTabStore.ID) {
        tabFocus.activate()
        store.select(id)
    }

    private func requestClose(_ id: AgentBookTabStore.ID) {
        guard store.tabs.contains(where: { $0.id == id }) else { return }
        tabFocus.activate()
        pendingCloseID = id
    }
}
