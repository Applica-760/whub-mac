import AppKit
import SwiftUI

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
    @ViewBuilder let container: (WorkspacePanes) -> Container
    @State private var leftFocus = TabPaneFocus()
    @State private var agentFocus = TabPaneFocus()

    var body: some View {
        let selection = Binding(get: { section }, set: selectSection)

        container(WorkspacePanes(section: section, leftFocus: leftFocus, agentFocus: agentFocus))
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            selection: selection,
            activateAgentBook: { agentFocus.activate() },
            newTab: newTab, targetsAgentBook: targetsAgentBook
        ))
    }

    private func selectSection(_ next: WorkspaceSection) {
        leftFocus.activate()
        section = next
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
    @EnvironmentObject private var agentBook: AgentBookStore

    var body: some View {
        HSplitView {
            RetainedPageContainer(selection: section) { page in
                page.content
            }
            .background(TabPaneFocusView(focus: leftFocus, activatesOnClick: false))
            .frame(minWidth: 300)
            AgentBookView(store: agentBook)
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
