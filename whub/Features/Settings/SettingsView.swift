import SwiftUI
import WhubCore

struct SettingsView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TabView {
            ProjectSettingsView()
                .padding()
                .tabItem { Label("Projects", systemImage: "folder") }

            HostSettingsView()
                .padding()
                .tabItem { Label("Hosts", systemImage: "desktopcomputer") }

            BookmarkSettingsView()
                .padding()
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }

            ActivityCategorySettingsView()
                .padding()
                .tabItem { Label("Categories", systemImage: "tag") }
        }
        .frame(width: 720, height: 480)
        .onExitCommand { dismissWindow() }
    }
}
