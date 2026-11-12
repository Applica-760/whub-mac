import SwiftUI

struct AppToolbar: ToolbarContent {
    @FocusedValue(\.toggleTerminal) private var toggleTerminal
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
        ToolbarItem(placement: .primaryAction) {
            Button("Term", systemImage: "terminal") {
                toggleTerminal?()
            }
            .disabled(toggleTerminal == nil)
            .help("Toggle Terminal (⌘I)")
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
