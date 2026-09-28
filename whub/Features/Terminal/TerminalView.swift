import SwiftTerm
import SwiftUI

struct TerminalView: View {
    var closeShortcutEnabled = true
    @EnvironmentObject private var store: TerminalStore
    @State private var pendingCloseID: TerminalSession.ID?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    TabBar(
                        title: "Term \(index + 1)",
                        icon: Image(systemName: "terminal"),
                        isSelected: session.id == store.selectedSessionID,
                        showsSelectionBorder: true,
                        isCloseDisabled: store.sessions.count == 1,
                        closeShortcutEnabled: closeShortcutEnabled,
                        status: store.attention[session.id]?.contains(.permission) == true
                            ? (.orange, "権限待ち")
                            : store.attention[session.id]?.contains(.completed) == true
                                ? (.green, "完了") : nil,
                        action: { store.select(session.id) },
                        closeAction: {
                            if session.hasRunningCommand {
                                pendingCloseID = session.id
                            } else {
                                store.remove(session.id)
                            }
                        }
                    )
                }

                Spacer()

                Button("Add Terminal", systemImage: "plus") {
                    store.add()
                }
                .keyboardShortcut("t", modifiers: .command)
                .labelStyle(.iconOnly)
            }

            TerminalWidget(session: store.selectedSession)
        }
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
