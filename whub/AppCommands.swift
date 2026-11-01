import AppKit
import SwiftUI

struct FeatureActions: FocusedValueKey {
    typealias Value = Self

    let selection: Binding<FeaturePage>
    let toggleAgentBook: () -> Void
    let targetsAgentBook: () -> Bool

    func movePage(_ offset: Int) {
        selection.wrappedValue = selection.wrappedValue.moved(by: offset)
    }
}

extension FocusedValues {
    var featureActions: FeatureActions? {
        get { self[FeatureActions.self] }
        set { self[FeatureActions.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.featureActions) private var featureActions
    let files: FilesStore
    let agentBookStore: AgentBookStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("新規タブ") {
                guard let window = NSApp.keyWindow else { return }
                CreateTab.perform(in: window)
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(featureActions == nil)
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
            ForEach(FeaturePage.allCases, id: \.self) { destination in
                Button(destination.label) { featureActions?.selection.wrappedValue = destination }
            }
            Divider()
            AgentBookTabMenu(store: agentBookStore, isActive: featureActions != nil,
                             isShortcutTarget: { featureActions?.targetsAgentBook() == true })
            Divider()
            Button("Toggle AgentBook") { featureActions?.toggleAgentBook() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(featureActions == nil)
            Button("Previous Page") { featureActions?.movePage(-1) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Next Page") { featureActions?.movePage(1) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            FilesNavigationMenu(store: files)
        }
    }
}
