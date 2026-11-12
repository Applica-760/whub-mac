import AppKit
import SwiftData
import SwiftUI
import WhubCore

struct ExplorerPulldownView: View {
    @ObservedObject var store: ExplorerStore
    var projects: [Project] = []
    var onOpenIssues: (URL) -> Void = { _ in }
    @State private var scrollSelection: FileLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                picker
                if let url = issueURL {
                    Button("Issues", systemImage: "dot.circle") { onOpenIssues(url) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Open GitHub Issues")
                }
                ExplorerLoadingView(store: store.remoteWorkspace, sources: store.remoteSources,
                                    treeLoading: store.remoteTree.states.values.contains(.loading))
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Divider().padding(.horizontal, 16)
            RemoteWorkspaceStatusView(store: store.remoteWorkspace, sources: store.remoteSources)
        }
        .focusedSceneValue(
            \.explorerPulldownSelection,
            ExplorerPulldownSelection(locations: store.locations, selection: $store.selectedLocation)
        )
    }

    private var picker: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(store.locations, id: \.self) { location in
                    Button {
                        store.selectedLocation = location
                    } label: {
                        Text(title(for: location))
                            .font(Font(NSFont.systemFont(
                                ofSize: NSFont.systemFontSize + (location == store.selectedLocation ? 1 : -2),
                                weight: location == store.selectedLocation
                                    ? .init((NSFont.Weight.regular.rawValue + NSFont.Weight.medium.rawValue) / 2)
                                    : .regular
                            )))
                            .opacity(location == store.selectedLocation ? 1 : 0.6)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(title(for: location))
                    .accessibilityAddTraits(location == store.selectedLocation ? .isSelected : [])
                    .id(location)
                }
            }
            .scrollTargetLayout()
        }
        .safeAreaPadding(.vertical, 24)
        .scrollIndicators(.hidden)
        .scrollEdgeEffectHidden()
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always, anchor: .center))
        .scrollPosition(id: $scrollSelection, anchor: .center)
        .frame(width: 130, height: 72)
        .onAppear { scrollSelection = store.selectedLocation }
        .onChange(of: store.selectedLocation) { _, location in scrollSelection = location }
        .onScrollPhaseChange { _, phase in
            if phase == .idle, let scrollSelection { store.selectedLocation = scrollSelection }
        }
    }

    private func title(for location: FileLocation) -> String {
        switch location {
        case let .local(url):
            if url.path == store.localBasePath { return "BasePath" }
            return store.projects.first { $0.path == url.path }?.name ?? location.name
        case let .remote(hostID, _):
            guard let source = store.remoteSources.first(where: { $0.hostID == hostID }) else { return location.name }
            return "\(location == source.baseLocation ? "BasePath" : location.name) · \(source.hostName)"
        }
    }

    private var issueURL: URL? {
        guard let location = store.selectedLocation,
              let project = projects.first(where: { project in
                  let matchesHost: Bool
                  switch location {
                  case .local: matchesHost = project.host is LocalHost
                  case let .remote(hostID, _): matchesHost = project.host.persistentModelID == hostID
                  }
                  return matchesHost && (location.path == project.path
                      || project.worktreeIssueNumber(for: location.path) != nil)
              }), let gitURL = project.gitURL else { return nil }
        return BrowserStore.githubIssuesURL(gitURL)
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

private struct ExplorerLoadingView: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sources: [RemoteWorkspaceStore.Source]
    let treeLoading: Bool

    private var isLoading: Bool {
        treeLoading || sources.contains { store.states[$0.hostID] == .loading }
    }

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 16, height: 16)
            .opacity(isLoading ? 1 : 0)
            .accessibilityLabel("一覧を取得中")
            .accessibilityHidden(!isLoading)
    }
}

struct RemoteWorkspaceStatusView: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sources: [RemoteWorkspaceStore.Source]

    var body: some View {
        ForEach(sources, id: \.hostID) { source in
            if let state = store.states[source.hostID] {
                switch state {
                case .loading: EmptyView()
                case let .failed(message):
                    Text("\(source.hostName)：\(message)")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                case .loaded: EmptyView()
                }
            }
        }
    }
}
