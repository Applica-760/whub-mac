import SwiftUI

struct RemoteWorkspaceMenuItems: View {
    @ObservedObject var store: RemoteWorkspaceStore
    let sources: [RemoteWorkspaceStore.Source]

    var body: some View {
        ForEach(sources, id: \.hostID) { source in
            let entries = store.entries(for: [source])
            if !entries.isEmpty {
                Divider()
                Section {
                    ForEach(entries) { entry in
                        Text(entry.name).tag(Optional(entry.id))
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

struct RemoteFileTreeStatusView: View {
    let states: [String: RemoteFileTreeStore.State]

    var body: some View {
        ForEach(states.keys.sorted(), id: \.self) { path in
            switch states[path] {
            case .loading:
                Text("\(path.isEmpty ? "ルート" : path)：取得中…")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            case let .failed(message):
                Text("\(path.isEmpty ? "ルート" : path)：\(message) — リロードで再取得")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            default: EmptyView()
            }
        }
    }
}
