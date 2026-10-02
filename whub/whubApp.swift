import AppKit
import SwiftData
import SwiftUI
import WhubCore

@main
struct whubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .containerBackground(.thinMaterial, for: .window)
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
                ForEach(Array(AppView.Section.allCases.enumerated()), id: \.element) { index, destination in
                    Button(destination.label) { section = destination }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                }
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

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "whubを終了しますか？"
        alert.informativeText = "未保存の編集内容は失われ、実行中のコマンドは中断されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\r"
        alert.addButton(withTitle: "終了").keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
