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
