import AppKit
import Combine
import SwiftTerm

private final class FixedCursorTerminalView: LocalProcessTerminalView {
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: .steadyBar)
    }
}

final class TerminalSession: Identifiable {
    let id = UUID()
    let terminal: LocalProcessTerminalView

    init() {
        let terminal = FixedCursorTerminalView(frame: .zero)
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.lineSpacing = 1.1
        terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        terminal.wantsLayer = true
        terminal.layer?.cornerRadius = 8
        terminal.layer?.masksToBounds = true
        terminal.terminal.setCursorStyle(.steadyBar)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            currentDirectory: "\(NSHomeDirectory())/workspace-hub"
        )
        self.terminal = terminal
    }

    deinit {
        terminal.terminate()
    }
}

final class TerminalStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var selectedSessionID: TerminalSession.ID

    init() {
        let session = TerminalSession()
        sessions = [session]
        selectedSessionID = session.id
    }

    var selectedSession: TerminalSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = TerminalSession()
        sessions.append(session)
        selectedSessionID = session.id
    }

    func remove(_ id: TerminalSession.ID) {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }

        sessions.remove(at: index)
        guard selectedSessionID == id else { return }
        selectedSessionID = sessions[min(index, sessions.endIndex - 1)].id
    }

    func select(_ id: TerminalSession.ID) {
        selectedSessionID = id
    }
}
