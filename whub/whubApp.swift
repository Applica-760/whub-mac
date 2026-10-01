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
    @FocusedValue(\.projectNavigation) private var projectNavigation
    private let workspaceContainer: ModelContainer

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
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
            CommandGroup(after: .newItem) {
                Button("新規タブ") {
                    switch section {
                    case .workspace: terminalStore.add()
                    case .browser: browserStore.add()
                    default: break
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(section != .workspace && section != .browser)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    guard NSApp.keyWindow?.firstResponder is CodeTextView else { return }
                    NSApp.sendAction(#selector(CodeTextView.saveDocument(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
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
                Button("Reload Files") { fileViewerStore.refresh() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Previous Project or Worktree") { projectNavigation?.move(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                    .disabled(projectNavigation == nil)
                Button("Next Project or Worktree") { projectNavigation?.move(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                    .disabled(projectNavigation == nil)
            }
        }

        Settings {
            SettingsView()
        }
        .modelContainer(workspaceContainer)
    }
}
