import AppKit
import SwiftUI

enum WorkspaceSection: CaseIterable, Hashable {
    case editor, terminal, overview

    var label: String {
        switch self {
        case .editor: "Editor"
        case .terminal: "Terminal"
        case .overview: "Overview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "doc.text"
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
        case .terminal: TerminalView()
        case .overview: OverviewView()
        }
    }
}

extension EnvironmentValues {
    @Entry var openWorkspaceEditor: @MainActor () -> Void = {}
}

struct WorkspaceActions {
    let selection: Binding<WorkspaceSection>
    let toggleAgentBook: () -> Void
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
    @EnvironmentObject private var terminal: TerminalStore
    @ViewBuilder let container: (WorkspacePanes) -> Container
    @State private var leftFocus = TabPaneFocus()
    @State private var agentFocus = TabPaneFocus()
    @State private var showsAgentBook = true

    var body: some View {
        let selection = Binding(get: { section }, set: selectSection)

        container(WorkspacePanes(section: section, leftFocus: leftFocus))
        .inspector(isPresented: $showsAgentBook) {
            AgentBookView(store: agentBook)
                .environment(\.openWorkspaceEditor, { selectSection(.editor) })
                .background(TabPaneFocusView(focus: agentFocus, activatesOnClick: false))
                .inspectorColumnWidth(min: 500, ideal: 600, max: 1200)
        }
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Toggle AgentBook", systemImage: "sidebar.right") {
                    showsAgentBook.toggle()
                }
            }
        }
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(
            selection: selection,
            toggleAgentBook: { showsAgentBook.toggle() },
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
            case .terminal: terminal.add()
            case .editor, .overview: break
            }
        }
    }
}

struct WorkspacePanes: NSViewRepresentable {
    let section: WorkspaceSection
    let leftFocus: TabPaneFocus
    @EnvironmentObject private var editor: EditorStore
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = AnyView(
            RetainedPageContainer(selection: section) { page in
                page.content.environmentObject(editor)
            }
                .background(TabPaneFocusView(focus: leftFocus, activatesOnClick: false))
                .environment(\.self, environment).environment(\.colorScheme, colorScheme)
        )
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
