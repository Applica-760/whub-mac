import AppKit
import SwiftUI

struct AppCommands: Commands {
    @FocusedValue(\.workspaceActions) private var workspaceActions
    let files: FilesStore
    let agentBookStore: AgentBookStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新規タブ") {
                workspaceActions?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workspaceActions == nil)
        }
        FilesCommands()
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("b", modifiers: .command)
            Button("Toggle Full Screen") {
                NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("Navigate") {
            ForEach(WorkspaceSection.allCases, id: \.self) { destination in
                Button(destination.label) { workspaceActions?.selection.wrappedValue = destination }
            }
            Divider()
            AgentBookTabMenu(store: agentBookStore, isActive: workspaceActions != nil,
                             isShortcutTarget: { workspaceActions?.targetsAgentBook() == true })
            Divider()
            Button("Focus AgentBook Input") { workspaceActions?.activateAgentBook() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(workspaceActions == nil)
            Button("Previous Page") { workspaceActions?.moveSection(-1) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Next Page") { workspaceActions?.moveSection(1) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            FilesNavigationMenu(store: files)
        }
    }
}
