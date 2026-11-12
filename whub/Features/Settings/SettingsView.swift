import SwiftUI

struct SettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TabView {
            BookmarkSettingsView()
                .padding()
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }

            ProjectSettingsView()
                .padding()
                .tabItem { Label("Projects", systemImage: "folder") }

            HostSettingsView()
                .padding()
                .tabItem { Label("Hosts", systemImage: "desktopcomputer") }
        }
        .frame(width: 960, height: 640)
        .onExitCommand { dismissWindow() }
    }
}

struct SettingsToolbar: ToolbarContent {
    @Environment(\.openSettings) private var openSettings

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
        }
    }
}
