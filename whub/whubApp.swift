import AppKit
import SwiftData
import SwiftUI
import WhubCore

@main
@MainActor
enum WhubLauncher {
    static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--markdown-ui-test") {
            MarkdownUITestApp.main()
            return
        }
        #endif
        whubApp.main()
    }
}

struct whubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var files = FilesStore()
    @StateObject private var terminalStore: TerminalStore
    @StateObject private var browserStore = BrowserStore()
    @StateObject private var agentBookStore: AgentBookStore
    @StateObject private var remoteConnections: RemoteConnectionStore
    @StateObject private var remoteServers: RemoteServerStore
    @State private var section = AppView.Section.workspace
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
            AppCommands(section: $section, files: files, terminalStore: terminalStore,
                        browserStore: browserStore, agentBookStore: agentBookStore)
        }

        Settings {
            SettingsView()
        }
        .modelContainer(workspaceContainer)
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
        let cancelButton = alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "終了").keyEquivalent = ""
        alert.window.defaultButtonCell = cancelButton.cell as? NSButtonCell
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
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
