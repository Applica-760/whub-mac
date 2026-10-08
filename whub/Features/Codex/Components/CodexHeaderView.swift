import AppKit
import SwiftUI

struct CodexHeaderView: View {
    @EnvironmentObject private var store: CodexStore
    let newConversation: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: chooseDirectory) {
                Label(URL(fileURLWithPath: store.directory).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
            .help(store.directory)
            .disabled(!store.canConfigure)
            Picker("権限", selection: $store.writable) {
                Text("読み取りのみ").tag(false)
                Text("編集可").tag(true)
            }
            .fixedSize()
            .disabled(!store.canConfigure)
            Spacer()
            Text(store.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("新しい会話", systemImage: "square.and.pencil") {
                newConversation()
            }
            .disabled(store.isBusy)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.directory)
        if panel.runModal() == .OK, let url = panel.url { store.directory = url.path }
    }
}
