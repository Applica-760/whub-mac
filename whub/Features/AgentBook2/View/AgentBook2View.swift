import AppKit
import Combine
import SwiftUI

struct AgentBook2View: View {
    @ObservedObject var store: AgentBook2Store
    @State private var tabFocus = TabPaneFocus()
    @State private var pendingCloseID: AgentBook2TabStore.ID?
    @Environment(\.retainedPageActivity) private var featureActivity

    var body: some View {
        RetainedPageContainer(selection: store.selectedTabID, availablePages: store.tabs.map(\.id)) { id in
            if let tab = store.tabs.first(where: { $0.id == id }) {
                AgentBook2TabView(bookStore: store, store: tab.store, tab: tab,
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
            Text(store.tabs.first { $0.id == pendingCloseID }?.store.target.disconnectMessage
                 ?? "このタブを閉じます。")
        }
    }

    private func select(_ id: AgentBook2TabStore.ID) {
        tabFocus.activate()
        store.select(id)
    }

    private func requestClose(_ id: AgentBook2TabStore.ID) {
        guard store.tabs.contains(where: { $0.id == id }) else { return }
        tabFocus.activate()
        pendingCloseID = id
    }
}

struct AgentBook2TabMenu: View {
    @ObservedObject var store: AgentBook2Store
    let isActive: Bool

    var body: some View {
        ForEach(1...9, id: \.self) { number in
            Button("AgentBook2 \(number)") {
                guard isActive, store.tabs.indices.contains(number - 1) else { return }
                store.select(store.tabs[number - 1].id)
            }
            .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            .disabled(!isActive || !store.tabs.indices.contains(number - 1))
        }
    }
}
