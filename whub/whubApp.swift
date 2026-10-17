import AppKit
import SwiftData
import SwiftUI
import WhubCore

@main
struct whubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var files = FilesStore()
    @StateObject private var terminalStore: TerminalStore
    @StateObject private var browserStore = BrowserStore()
    @StateObject private var agentBookStore: AgentBookStore
    @StateObject private var remoteConnections: RemoteConnectionStore
    @StateObject private var remoteServers: RemoteServerStore
    @State private var section = AppView.Section.agentBook
    private let workspaceContainer: ModelContainer

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let connections = RemoteConnectionStore()
        _remoteConnections = StateObject(wrappedValue: connections)
        _remoteServers = StateObject(wrappedValue: RemoteServerStore(connections: connections))
        do {
            let container = try Container.make()
            workspaceContainer = container
            _terminalStore = StateObject(wrappedValue: TerminalStore(context: container.mainContext))
            _agentBookStore = StateObject(wrappedValue: AgentBookStore(context: container.mainContext))
        } catch {
            fatalError("Unable to open workspace store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView(section: $section)
                .containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
                .environmentObject(files)
                .environmentObject(files.activeEditor)
                .environmentObject(files.git)
                .environmentObject(terminalStore)
                .environmentObject(browserStore)
                .environmentObject(agentBookStore)
                .environmentObject(remoteConnections)
                .environmentObject(remoteServers)
                .onAppear {
                    appDelegate.remoteConnections = remoteConnections
                    appDelegate.remoteServers = remoteServers
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    agentBookStore.disconnect()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    files.checkForExternalChanges()
                }
        }
        .windowResizability(.contentMinSize)
        .modelContainer(workspaceContainer)
        .commands {
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
    weak var remoteServers: RemoteServerStore?
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
            await remoteServers?.close()
            await remoteConnections.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
