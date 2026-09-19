//
//  whubApp.swift
//  whub
//
//  Created by 村上匠 on 2026/09/10.
//

import AppKit
import SwiftData
import SwiftUI
import WhubCore

@main
struct whubApp: App {
    @StateObject private var fileViewerStore = FileViewerStore()
    @StateObject private var terminalStore = TerminalStore()
    @StateObject private var browserStore = BrowserStore()
    @State private var section = AppView.Section.overview
    private let workspaceContainer: ModelContainer

    init() {
        do {
            workspaceContainer = try Container.make()
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
        }

        Settings {
            SettingsView()
        }
        .modelContainer(workspaceContainer)
    }
}
