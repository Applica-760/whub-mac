import SwiftTerm
import SwiftUI
import MetalKit

struct TerminalView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @State private var tabFocus = TabPaneFocus()
    @EnvironmentObject private var store: TerminalStore
    @State private var pendingCloseID: TerminalSession.ID?

    var body: some View {
        WidgetFrame {
            LocalTerminalView(terminal: store.selectedSession.terminal)
                .id(store.selectedSession.id)
                .frame(maxWidth: .infinity, minHeight: 240)
                .padding(6)
                .background(Color(white: 0.07).opacity(0.75))
        } header: {
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
                        action: actions.select,
                        closeAction: actions.close
                    )
                }
            }
        }
        .background(TabPaneFocusView(focus: tabFocus))
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
        .onChange(of: store.selectedSessionID, initial: true) { _, _ in
            focusTerminal()
        }
        .onChange(of: isActive) { _, active in
            if active { focusTerminal() }
        }
    }

    private func focusTerminal() {
        guard isActive else { return }
        DispatchQueue.main.async {
            let terminal = store.selectedSession.terminal
            guard !terminal.isHiddenOrHasHiddenAncestor else { return }
            terminal.window?.makeFirstResponder(terminal)
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

private struct LocalTerminalView: NSViewRepresentable {
    @Environment(\.isRetainedPageActive) private var isActive
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return terminal
    }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        for renderer in terminal.subviews.compactMap({ $0 as? MTKView }) {
            guard renderer.enableSetNeedsDisplay != isActive else { continue }
            renderer.enableSetNeedsDisplay = isActive
            if isActive { renderer.setNeedsDisplay(renderer.bounds) }
        }
    }
}
