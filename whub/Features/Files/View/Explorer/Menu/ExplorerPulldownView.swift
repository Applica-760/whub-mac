import SwiftData
import SwiftUI
import WhubCore

struct ExplorerPulldownView: View {
    @ObservedObject var store: ExplorerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                picker
                // Reserve the menu trigger position; the expanded menu overlays the explorer.
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal)
            .padding(.top)

            Divider().padding(.horizontal)
            RemoteWorkspaceStatusView(store: store.remoteWorkspace, sources: store.remoteSources)
        }
        .focusedSceneValue(
            \.explorerPulldownSelection,
            ExplorerPulldownSelection(locations: store.locations, selection: $store.selectedLocation)
        )
    }

    private var picker: some View {
        Picker("Project or Worktree", selection: $store.selectedLocation) {
            if store.locations.isEmpty {
                Text("---").tag(FileLocation?.none)
            }
            if let basePath = store.localBasePath {
                Text("BasePath").tag(Optional(FileLocation.local(URL(fileURLWithPath: basePath))))
                Divider()
            }
            ForEach(store.projects) { project in
                Text(project.name).tag(Optional(FileLocation.local(URL(fileURLWithPath: project.path))))
            }
            ForEach(store.worktreeURLs, id: \.self) { url in
                Text(url.lastPathComponent).tag(Optional(FileLocation.local(url)))
            }
            RemoteWorkspaceMenuItems(store: store.remoteWorkspace, sources: store.remoteSources)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

struct RemoteWorkspaceMenuItems: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sources: [RemoteWorkspaceStore.Source]

    var body: some View {
        ForEach(sources, id: \.hostID) { source in
            let entries = store.entries(for: [source])
            if !entries.isEmpty {
                Divider()
                Section {
                    ForEach(entries, id: \.self) { entry in
                        Text(entry == source.baseLocation ? "BasePath" : entry.name).tag(Optional(entry))
                    }
                } header: {
                    Text(source.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct RemoteWorkspaceStatusView: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sources: [RemoteWorkspaceStore.Source]

    var body: some View {
        ForEach(sources, id: \.hostID) { source in
            if let state = store.states[source.hostID] {
                switch state {
                case .loading:
                    Text("\(source.hostName)：一覧を取得中…")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                case let .failed(message):
                    Text("\(source.hostName)：\(message)")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                case .loaded: EmptyView()
                }
            }
        }
    }
}
