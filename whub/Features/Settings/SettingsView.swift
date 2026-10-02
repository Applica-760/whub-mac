import SwiftUI
import WhubCore

struct SettingsView: View {
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
        }
        .frame(width: 720, height: 480)
    }
}
