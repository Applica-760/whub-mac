import SwiftUI

struct AppToolbar: ToolbarContent {
    @Binding var selection: FeaturePage
    @Binding var showsAgentBook: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("ページ", selection: $selection) {
                ForEach(FeaturePage.allCases, id: \.self) { page in
                    Label(page.label, systemImage: page.systemImage).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        RemoteConnectionToolbar()
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Toggle AgentBook", systemImage: "sidebar.right") {
                showsAgentBook.toggle()
            }
        }
    }
}
