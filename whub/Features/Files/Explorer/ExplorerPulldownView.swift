import SwiftData
import SwiftUI
import WhubCore

struct ExplorerPulldownView: View {
    @Binding var selection: FileLocation?
    let locations: [FileLocation]
    let localBasePath: String?
    let projects: [Project]
    let worktreeURLs: [URL]
    @ObservedObject var remoteStore: RemoteWorkspaceStore
    let remoteSources: [RemoteWorkspaceStore.Source]

    var body: some View {
        Picker("Project or Worktree", selection: $selection) {
            if locations.isEmpty {
                Text("---").tag(FileLocation?.none)
            }
            if let localBasePath {
                Text("BasePath").tag(Optional(FileLocation.local(URL(fileURLWithPath: localBasePath))))
                Divider()
            }
            ForEach(projects.filter { $0.host is LocalHost }) { project in
                Text(project.name).tag(Optional(FileLocation.local(URL(fileURLWithPath: project.path))))
            }
            ForEach(worktreeURLs, id: \.self) { url in
                Text(url.lastPathComponent).tag(Optional(FileLocation.local(url)))
            }
            RemoteWorkspaceMenuItems(store: remoteStore, sources: remoteSources)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .focusedSceneValue(
            \.explorerPulldownSelection,
            ExplorerPulldownSelection(locations: locations, selection: $selection)
        )
    }
}

struct ExplorerPulldownSelection {
    let locations: [FileLocation]
    @Binding var selection: FileLocation?

    func move(by offset: Int) {
        guard let index = locations.firstIndex(where: { $0 == selection }),
              locations.indices.contains(index + offset) else { return }
        selection = locations[index + offset]
    }
}

private struct ExplorerPulldownSelectionKey: FocusedValueKey {
    typealias Value = ExplorerPulldownSelection
}

extension FocusedValues {
    var explorerPulldownSelection: ExplorerPulldownSelection? {
        get { self[ExplorerPulldownSelectionKey.self] }
        set { self[ExplorerPulldownSelectionKey.self] = newValue }
    }
}
