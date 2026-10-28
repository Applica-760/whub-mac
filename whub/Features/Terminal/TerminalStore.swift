import AppKit
import Combine
import Darwin
import MetalKit
import SwiftData
import SwiftTerm
import WhubCore

private final class FixedCursorTerminalView: LocalProcessTerminalView {
    private var appearanceObservation: NSKeyValueObservation?

    func followSystemAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.applyAppearance(app.effectiveAppearance)
            }
        }
    }

    private func applyAppearance(_ appearance: NSAppearance) {
        self.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
            nativeForegroundColor = nativeForegroundColor.usingColorSpace(.sRGB) ?? nativeForegroundColor
            nativeBackgroundColor = nativeBackgroundColor.usingColorSpace(.sRGB) ?? nativeBackgroundColor
            caretColor = nativeForegroundColor
            selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? .selectedTextBackgroundColor
            selectedTextForegroundColor = NSColor.selectedTextColor.usingColorSpace(.sRGB) ?? .selectedTextColor
            layer?.backgroundColor = nativeBackgroundColor.cgColor
            colorChanged(source: terminal, idx: nil)
        }
        for renderer in subviews.compactMap({ $0 as? MTKView }) {
            renderer.setNeedsDisplay(renderer.bounds)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is MTKView ? self : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        fontSmoothing = false
        metalScaleFactorOverride = window.backingScaleFactor * 2
        do {
            try setUseMetal(true)
            for metalView in subviews.compactMap({ $0 as? MTKView }) {
                metalView.layer?.isOpaque = false
            }
        } catch {
            NSLog("Terminal Metal renderer unavailable: %@", error.localizedDescription)
        }
    }

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

    init(terminal: LocalProcessTerminalView) {
        self.terminal = terminal
    }

    convenience init(currentDirectory: String) {
        let terminal = FixedCursorTerminalView(frame: .zero)
        for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
            scroller.isHidden = true
        }
        terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        terminal.lineSpacing = 1.1
        terminal.followSystemAppearance()
        terminal.terminal.setCursorStyle(.steadyBar)
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            currentDirectory: currentDirectory
        )
        self.init(terminal: terminal)
    }

    deinit {
        terminal.terminate()
    }
}

@MainActor
final class TerminalStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var selectedSessionID: TerminalSession.ID
    private let context: ModelContext
    private let makeSession: @MainActor (String) -> TerminalSession

    init(context: ModelContext, makeSession: @escaping @MainActor (String) -> TerminalSession = TerminalSession.init(currentDirectory:)) {
        self.context = context
        self.makeSession = makeSession
        let session = makeSession(Self.currentDirectory(in: context))
        sessions = [session]
        selectedSessionID = session.id
    }

    var selectedSession: TerminalSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    func add() {
        let session = makeSession(Self.currentDirectory(in: context))
        sessions.append(session)
        selectedSessionID = session.id
    }

    func remove(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id })
        else { return }

        if sessions.count == 1 {
            let replacement = makeSession(Self.currentDirectory(in: context))
            sessions = [replacement]
            selectedSessionID = replacement.id
            return
        }
        sessions.remove(at: index)
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
    }

    private static func currentDirectory(in context: ModelContext) -> String {
        (try? HostStore(context: context).fetchHosts().first { $0 is LocalHost }?.basePath)
            ?? NSHomeDirectory()
    }
}
