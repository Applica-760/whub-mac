import Combine
import SwiftTerm
import SwiftUI
import SwiftData
import MetalKit

struct TerminalView: View {
    @Environment(\.isRetainedPageActive) private var isActive
    @State private var tabFocus = TabPaneFocus()
    @StateObject private var store: TerminalStore
    @State private var pendingCloseID: TerminalSession.ID?

    init(store: @autoclosure @escaping () -> TerminalStore) {
        _store = StateObject(wrappedValue: store())
    }

    var body: some View {
        WidgetFrame {
            LocalTerminalView(terminal: store.selectedSession.terminal)
                .id(store.selectedSession.id)
                .frame(maxWidth: .infinity, minHeight: 100)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
        } header: {
            TabBarContainer(
                ids: store.sessions.map(\.id),
                selection: store.selectedSessionID,
                create: store.add,
                select: { id in
                    tabFocus.activate()
                    store.select(id)
                },
                close: requestClose,
                canClose: { _ in true },
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
            if active { focusTerminal(preservingOtherPane: true) }
        }
    }

    private func focusTerminal(preservingOtherPane: Bool = false) {
        guard isActive else { return }
        DispatchQueue.main.async {
            let terminal = store.selectedSession.terminal
            guard !terminal.isHiddenOrHasHiddenAncestor, terminal.window?.isKeyWindow == true else { return }
            if preservingOtherPane, let window = terminal.window,
               let responder = window.firstResponder as? NSView,
               !responder.isHiddenOrHasHiddenAncestor, !tabFocus.contains(window) { return }
            terminal.window?.makeFirstResponder(terminal)
        }
    }

    private func requestClose(_ id: TerminalSession.ID) {
        guard let session = store.sessions.first(where: { $0.id == id }) else { return }
        tabFocus.activate()
        if session.hasRunningCommand {
            pendingCloseID = id
        } else {
            store.remove(id)
        }
    }
}

struct LocalTerminalView: NSViewRepresentable {
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        return terminal
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ terminal: LocalProcessTerminalView, context: Context) {
        context.coordinator.subscription = activity?.isActive.sink { [weak terminal] active in
            if let terminal { Coordinator.setRendering(terminal, active: active) }
        }
        Coordinator.setRendering(terminal, active: activity?.isActive.value ?? isActive)
    }

    static func dismantleNSView(_ terminal: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.subscription = nil
        Coordinator.setRendering(terminal, active: false)
    }

    final class Coordinator {
        var subscription: AnyCancellable?

        static func setRendering(_ terminal: LocalProcessTerminalView, active: Bool) {
            for renderer in terminal.subviews.compactMap({ $0 as? MTKView }) {
                guard renderer.enableSetNeedsDisplay != active else { continue }
                renderer.enableSetNeedsDisplay = active
                if active { renderer.setNeedsDisplay(renderer.bounds) }
            }
        }
    }
}
