import SwiftUI
import WhubCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ProjectTable()
                .padding()
                .tabItem { Label("Projects", systemImage: "folder") }

            BookmarkSettingsView()
                .padding()
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }
        }
        .frame(width: 720, height: 480)
    }
}
