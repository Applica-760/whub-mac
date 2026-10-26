#if DEBUG
import SwiftUI

// Entered before whubApp initializes its database, shell, or connections.
struct MarkdownUITestApp: App {
    @StateObject private var files: FilesStore
    private let scheme: ColorScheme

    init() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WHUB_UI_TEST_DIRECTORY"] else {
            fatalError("Markdown UI tests require a fixture directory")
        }
        let files = FilesStore()
        for name in ["First", "Second"] {
            let location = FileLocation.local(URL(fileURLWithPath: path).appendingPathComponent(name + ".md"))
            files.activeEditor.local.load(location)
            files.activeEditor.open(.file(location))
        }
        _files = StateObject(wrappedValue: files)
        scheme = environment["WHUB_UI_TEST_APPEARANCE"] == "dark" ? .dark : .light
    }

    var body: some Scene {
        WindowGroup("Markdown UI Test") {
            EditorView()
                .environmentObject(files)
                .environmentObject(files.activeEditor)
                .environmentObject(files.git)
                .preferredColorScheme(scheme)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .defaultSize(width: 1100, height: 700)
    }
}
#endif
