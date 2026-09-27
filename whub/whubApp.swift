import AppKit
import SwiftData
import SwiftUI
import WhubCore

@main
struct whubApp: App {
    @StateObject private var fileViewerStore = FileViewerStore()
    @StateObject private var terminalStore: TerminalStore
    @StateObject private var browserStore = BrowserStore()
    @State private var section = AppView.Section.workspace
    private let workspaceContainer: ModelContainer

    init() {
        do {
            let container = try Container.make()
            workspaceContainer = container
            _terminalStore = StateObject(wrappedValue: TerminalStore(context: container.mainContext))
        } catch {
            fatalError("Unable to open workspace store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView(section: $section)
                .environmentObject(fileViewerStore)
                .environmentObject(terminalStore)
                .environmentObject(browserStore)
        }
        .modelContainer(workspaceContainer)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Full Screen") {
                    NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu("Navigate") {
                Button("Workspace") { section = .workspace }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Browser") { section = .browser }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
        .modelContainer(workspaceContainer)
    }
}
