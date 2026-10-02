import AppKit
import Combine
import CoreFoundation
import Darwin
import SwiftData
import SwiftTerm
import WhubCore

enum TerminalAttention: String, CaseIterable, Hashable {
    case permission
    case completed

    var sound: NSSound.Name {
        self == .permission ? NSSound.Name("Ping") : NSSound.Name("Glass")
    }
}

private final class FixedCursorTerminalView: LocalProcessTerminalView {
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: .steadyBar)
    }
}

final class TerminalSession: Identifiable {
    let id = UUID()
    let terminal: LocalProcessTerminalView

    var hasRunningCommand: Bool {
        let shellPID = terminal.process?.shellPid ?? 0
        var childPID: pid_t = 0
        return shellPID > 0
            && proc_listchildpids(shellPID, &childPID, Int32(MemoryLayout<pid_t>.size)) != 0
    }

    init(currentDirectory: String) {
        let terminal = FixedCursorTerminalView(frame: .zero)
        for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
            scroller.isHidden = true
        }
        terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.lineSpacing = 1.1
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        terminal.terminal.setCursorStyle(.steadyBar)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                + ["WHUB_MAC_TAB_ID=\(id.uuidString)"],
            currentDirectory: currentDirectory
        )
        self.terminal = terminal
    }

    deinit {
        terminal.terminate()
    }
}

@MainActor
final class TerminalStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var selectedSessionID: TerminalSession.ID
    @Published private(set) var attention: [TerminalSession.ID: Set<TerminalAttention>] = [:]
    private let context: ModelContext
    private var notificationNames: [TerminalSession.ID: [String]] = [:]

    init(context: ModelContext) {
        self.context = context
        let session = TerminalSession(currentDirectory: Self.currentDirectory(in: context))
        sessions = [session]
        selectedSessionID = session.id
        observe(session)

    }

    deinit {
        for names in notificationNames.values {
            for name in names { unobserve(name) }
        }
    }

    var selectedSession: TerminalSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = TerminalSession(currentDirectory: Self.currentDirectory(in: context))
        observe(session)
        sessions.append(session)
        selectedSessionID = session.id
    }

    func remove(_ id: TerminalSession.ID) {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }

        sessions.remove(at: index)
        for name in notificationNames.removeValue(forKey: id) ?? [] { unobserve(name) }
        attention.removeValue(forKey: id)
        guard selectedSessionID == id else { return }
        selectedSessionID = sessions[min(index, sessions.endIndex - 1)].id
    }

    func move(_ id: TerminalSession.ID, before target: TerminalSession.ID?) {
        guard let reordered = reorderedTabs(sessions, moving: id, before: target, identifiedBy: \.id)
        else { return }
        sessions = reordered
    }

    func select(_ id: TerminalSession.ID) {
        selectedSessionID = id
        attention.removeValue(forKey: id)
    }

    private func observe(_ session: TerminalSession) {
        for event in TerminalAttention.allCases {
            let name = "app.whub.terminal.\(session.id.uuidString).\(event.rawValue)"
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let store = Unmanaged<TerminalStore>.fromOpaque(observer).takeUnretainedValue()
                    Task { @MainActor in store.receive(name.rawValue as String) }
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
            notificationNames[session.id, default: []].append(name)
        }
    }

    nonisolated private func unobserve(_ name: String) {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }

    private func receive(_ name: String) {
        for session in sessions {
            for event in TerminalAttention.allCases {
                guard name == "app.whub.terminal.\(session.id.uuidString).\(event.rawValue)" else { continue }
                attention[session.id, default: []].insert(event)
                NSSound(named: event.sound)?.play()
                return
            }
        }
    }

    private static func currentDirectory(in context: ModelContext) -> String {
        (try? HostStore(context: context).fetchHosts().first { $0 is LocalHost }?.basePath)
            ?? NSHomeDirectory()
    }
}
