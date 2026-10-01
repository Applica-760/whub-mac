import SwiftTerm
import SwiftUI

struct TerminalView: View {
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: TerminalStore
    @State private var pendingCloseID: TerminalSession.ID?

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
                isShortcutTarget: { window in
                    pendingCloseID == nil && tabFocus.contains(window)
                }
            ) { id, isSelected, actions in
                if let index = store.sessions.firstIndex(where: { $0.id == id }) {
                    TabBar(
                        title: "Term \(index + 1)",
                        icon: Image(systemName: "terminal"),
                        isSelected: isSelected,
                        isCloseDisabled: store.sessions.count == 1,
                        status: store.attention[id]?.contains(.permission) == true
                            ? (.orange, "権限待ち")
                            : store.attention[id]?.contains(.completed) == true
                                ? (.green, "完了") : nil,
                        action: actions.select,
                        closeAction: actions.close
                    )
                }
            } trailing: {
                Button("Add Terminal", systemImage: "plus") {
                    store.add()
                }
                .keyboardShortcut("t", modifiers: .command)
                .labelStyle(.iconOnly)
            }

            TerminalWidget(session: store.selectedSession)
        }
        .background(TabPaneFocusView(focus: tabFocus))
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .navigationTitle("Terminal")
        .alert("実行中のコマンドがあります", isPresented: Binding(
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
            Text("このターミナルタブを閉じると、実行中のコマンドが中断されます。")
        }
        .onChange(of: store.selectedSessionID) { _, _ in
            DispatchQueue.main.async {
                let terminal = store.selectedSession.terminal
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }

    private func requestClose(_ id: TerminalSession.ID) {
        guard store.sessions.count > 1,
              let session = store.sessions.first(where: { $0.id == id }) else { return }
        tabFocus.activate()
        if session.hasRunningCommand {
            pendingCloseID = id
        } else {
            store.remove(id)
        }
    }
}

struct TerminalWidget: View {
    let session: TerminalSession

    var body: some View {
        WidgetFrame {
            LocalTerminalView(terminal: session.terminal)
                .id(session.id)
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}

private struct LocalTerminalView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {}
}
