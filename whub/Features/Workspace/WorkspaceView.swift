import AppKit
import SwiftData
import SwiftUI
import WhubCore

enum WorkspaceSection: CaseIterable, Hashable {
    case editor, browser, terminal, overview

    var label: String {
        switch self {
        case .editor: "Editor"
        case .browser: "Browser"
        case .terminal: "Terminal"
        case .overview: "Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "doc.text"
        case .browser: "globe"
        case .terminal: "terminal"
        case .overview: "rectangle.3.group"
        }
    }

    func moved(by offset: Int) -> Self {
        let sections = Self.allCases
        let index = sections.firstIndex(of: self)!
        return sections[((index + offset) % sections.count + sections.count) % sections.count]
    }

    @ViewBuilder var content: some View {
        switch self {
        case .editor: EditorView()
        case .browser: BrowserView()
        case .terminal: TerminalView()
        case .overview: OverviewView()
        }
    }
}

struct WorkspaceActions {
    let selection: Binding<WorkspaceSection>
    let activateAgentBook: () -> Void
    let newTab: () -> Void
    let targetsAgentBook: () -> Bool

    func moveSection(_ offset: Int) {
        selection.wrappedValue = selection.wrappedValue.moved(by: offset)
    }
}

private struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

struct WorkspaceView<Container: View>: View {
    @Binding var section: WorkspaceSection
    @EnvironmentObject private var agentBook: AgentBookStore
    @EnvironmentObject private var browser: BrowserStore
    @EnvironmentObject private var terminal: TerminalStore
    @EnvironmentObject private var files: FilesStore
    @EnvironmentObject private var connections: RemoteConnectionStore
    @EnvironmentObject private var servers: RemoteServerStore
    @ViewBuilder let container: (WorkspacePanes) -> Container
    @State private var leftFocus = TabPaneFocus()
    @State private var agentFocus = TabPaneFocus()
    @State private var agentInputFocus = AgentBookFocus()

    var body: some View {
        let selection = Binding(get: { section }, set: selectSection)

        container(WorkspacePanes(section: section, leftFocus: leftFocus, agentFocus: agentFocus, agentInputFocus: agentInputFocus, openLink: openLink))
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            selection: selection,
            activateAgentBook: { agentInputFocus.activateInput() },
            newTab: newTab, targetsAgentBook: targetsAgentBook
        ))
    }

    private func selectSection(_ next: WorkspaceSection) {
        leftFocus.activate()
        section = next
    }

    private func openLink(_ url: URL, store: AgentStore) -> Bool {
        if ["http", "https"].contains(url.scheme?.lowercased()) {
            browser.open(url)
            selectSection(.browser)
            return true
        }
        guard let path = Self.filePath(for: url, directory: store.directory) else { return false }
        let location: FileLocation
        let root: FileLocation?
        let hosts: [WhubCore.Host]
        switch store.target {
        case .local:
            location = .local(URL(fileURLWithPath: path))
            root = nil
            hosts = []
        case .remote(let host, _):
            location = .remote(hostID: host.persistentModelID, path: path)
            root = .remote(hostID: host.persistentModelID, path: (path as NSString).deletingLastPathComponent)
            hosts = [host]
        }
        files.open(location, hosts: hosts, connections: connections, servers: servers, root: root)
        selectSection(.editor)
        return true
    }

    static func filePath(for url: URL, directory: String?) -> String? {
        let raw = url.isFileURL ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        let path = raw.replacingOccurrences(of: #"(?::[0-9]+(?::[0-9]+)?|#L[0-9]+(?:-L[0-9]+)?)$"#,
                                            with: "", options: .regularExpression)
        guard !path.isEmpty, url.isFileURL || URL(string: path)?.scheme == nil else { return nil }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        guard let directory, directory.hasPrefix("/") else { return nil }
        return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private func targetsAgentBook() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return agentFocus.contains(window)
    }

    private func newTab() {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
        if agentFocus.contains(window) {
            agentBook.add()
        } else if leftFocus.contains(window) {
            switch section {
            case .browser: browser.add()
            case .terminal: terminal.add()
            case .editor, .overview: break
            }
        }
    }
}

struct WorkspacePanes: View {
    let section: WorkspaceSection
    let leftFocus: TabPaneFocus
    let agentFocus: TabPaneFocus
    let agentInputFocus: AgentBookFocus
    let openLink: (URL, AgentStore) -> Bool
    @EnvironmentObject private var agentBook: AgentBookStore

    var body: some View {
        HSplitView {
            RetainedPageContainer(selection: section) { page in
                page.content
            }
            .background(TabPaneFocusView(focus: leftFocus, activatesOnClick: false))
            .frame(minWidth: 300)
            AgentBookView(store: agentBook, inputFocus: agentInputFocus, openLink: openLink)
                .background(TabPaneFocusView(focus: agentFocus, activatesOnClick: false))
                .frame(minWidth: 700)
        }
    }
}

struct WorkspaceToolbar: ToolbarContent {
    @Binding var selection: WorkspaceSection

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("ページ", selection: $selection) {
                ForEach(WorkspaceSection.allCases, id: \.self) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
