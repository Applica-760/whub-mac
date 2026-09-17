import SwiftTerm
import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var store: TerminalStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    TabBar(
                        title: "Terminal \(index + 1)",
                        systemImage: "terminal",
                        isSelected: session.id == store.selectedSessionID
                    ) {
                        store.select(session.id)
                    }
                }

                Spacer()

                ControlGroup {
                    Button("Add Terminal", systemImage: "plus") {
                        store.add()
                    }
                    .keyboardShortcut("t", modifiers: .command)
                    Button("Close Terminal", systemImage: "minus") {
                        store.removeSelected()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(store.sessions.count == 1)
                }
                .controlGroupStyle(.automatic)
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
