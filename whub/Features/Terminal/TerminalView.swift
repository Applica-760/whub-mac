import SwiftTerm
import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    TabBar(
                        title: "Term \(index + 1)",
                        systemImage: "terminal",
                        isSelected: session.id == store.selectedSessionID,
                        isCloseDisabled: store.sessions.count == 1,
                        action: {
                            store.select(session.id)
                        },
                        closeAction: {
                            store.remove(session.id)
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

#Preview {
    TerminalView()
        .environmentObject(TerminalStore())
}
