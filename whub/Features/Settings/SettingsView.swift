import SwiftUI
import WhubCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ContentUnavailableView(
                "General",
                systemImage: "gearshape",
                description: Text("General settings will be available here.")
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            ProjectTable()
                .padding()
                .tabItem { Label("Projects", systemImage: "folder") }
        }
        .frame(width: 720, height: 480)
    }
}

#Preview {
    SettingsView()
}
