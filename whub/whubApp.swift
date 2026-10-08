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
    @StateObject private var remoteConnections = RemoteConnectionStore()
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
                .environmentObject(remoteConnections)
                .onAppear { appDelegate.remoteConnections = remoteConnections }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    fileViewerStore.checkForExternalChanges()
                }
        }
        .windowResizability(.contentMinSize)
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
                ForEach(AppView.Section.allCases, id: \.self) { destination in
                    Button(destination.label) { section = destination }
                }
                Button("Previous Page") { moveSection(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Button("Next Page") { moveSection(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
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

    private func moveSection(by offset: Int) {
        let sections = AppView.Section.allCases
        guard let index = sections.firstIndex(of: section) else { return }
        section = sections[(index + offset + sections.count) % sections.count]
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var remoteConnections: RemoteConnectionStore?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        let alert = NSAlert()
        alert.messageText = "whubを終了しますか？"
        alert.informativeText = "未保存の編集内容は失われ、実行中のコマンドは中断されます。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "キャンセル").keyEquivalent = "\r"
        alert.addButton(withTitle: "終了").keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        guard let remoteConnections else { return .terminateNow }
        isTerminating = true
        Task {
            await remoteConnections.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
