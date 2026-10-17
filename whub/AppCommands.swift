import AppKit
import SwiftUI

struct AppCommands: Commands {
    @Binding var section: AppView.Section
    let files: FilesStore
    let terminalStore: TerminalStore
    let browserStore: BrowserStore
    let agentBookStore: AgentBookStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新規タブ") {
                switch section {
                case .terminal: terminalStore.add()
                case .browser: browserStore.add()
                case .agentBook: agentBookStore.add()
                default: break
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(section != .terminal && section != .browser && section != .agentBook)
        }
        FilesCommands()
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Full Screen") {
                NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("Navigate") {
            ForEach(AppView.Section.allCases, id: \.self) { destination in
                Button(destination.label) { section = destination }
            }
            Divider()
            AgentBookTabMenu(store: agentBookStore, isActive: section == .agentBook)
            Divider()
            Button("Previous Page") { moveSection(by: -1) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Next Page") { moveSection(by: 1) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            FilesNavigationMenu(store: files)
        }
    }

    private func moveSection(by offset: Int) {
        let sections = AppView.Section.allCases
        guard let index = sections.firstIndex(of: section) else { return }
        section = sections[(index + offset + sections.count) % sections.count]
    }
}
