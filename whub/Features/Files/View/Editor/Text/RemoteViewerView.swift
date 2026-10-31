import AppKit
import SwiftUI
import WhubClient

struct RemoteViewerView: View {
    @ObservedObject var store: RemoteEditorStore
    let git: RemoteGitStore?
    let location: FileLocation
    let editorID: String
    let showsMarkdownPreview: Bool

    private var isImage: Bool { store.fileStores[location]?.isImage == true }
    private var hasImage: Bool { store.fileStores[location]?.image != nil }

    var body: some View {
        VStack(spacing: 0) {
            switch store.states[location] {
            case .loading:
                EmptyView()
            case let .failed(message):
                Text("\(message)\n\(isImage ? (hasImage ? "前回の画像を表示しています。" : "リロードで再取得できます。") : (store.file(for: location) == nil ? "リロードで再取得できます。" : "本文・編集内容は保持されています。最新状態を確認できません。"))")
                    .foregroundStyle(.orange).padding(8)
            case .disconnected:
                Text(isImage ? "切断しました。" : "切断しました。編集内容は保持されています。")
                    .foregroundStyle(.orange).padding(8)
            case .loaded, nil:
                EmptyView()
            }
            if let remote = store.fileStores[location] {
                if let message = remote.message { Text(message).foregroundStyle(.orange).padding(8) }
            }
            if let image = store.fileStores[location]?.image {
                ImagePreviewView(image: image).accessibilityLabel(location.name)
            } else if let file = store.file(for: location), case let .text(source) = file.content {
                MarkdownSplitView(source: source, showsPreview: showsMarkdownPreview) {
                    if let git {
                        RemoteCodeEditorView(git: git, location: location, file: file, source: source, editorID: editorID)
                    } else {
                        CodeEditorView(state: file, editorID: editorID, onEdit: {}, source: source,
                                       language: codeLanguages[(location.name as NSString).pathExtension.lowercased()], hunks: [], location: location)
                            .background(Color(nsColor: .textBackgroundColor))
                    }
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RemoteCodeEditorView: View {
    @ObservedObject var git: RemoteGitStore
    let location: FileLocation
    let file: FileStore
    let source: String
    let editorID: String
    @StateObject private var diffStore = GitLineStore()
    @State private var usageID = UUID()
    @Environment(\.isRetainedPageActive) private var isActive

    private var path: String? {
        let prefix = git.root.path == "/" ? "/" : git.root.path + "/"
        guard case let .remote(hostID, _) = location, case let .remote(rootHostID, _) = git.root,
              hostID == rootHostID, location.path.hasPrefix(prefix) else { return nil }
        return String(location.path.dropFirst(prefix.count))
    }

    private var baseline: String? {
        guard isActive, git.isConnected, git.watchError == nil, git.errorMessage == nil,
              let path, let diff = git.diffs[path], diff.content.type == "text" else { return nil }
        return diff.content.before
    }

    var body: some View {
        CodeEditorView(state: file, editorID: editorID, onEdit: {}, source: source,
                       language: codeLanguages[(location.name as NSString).pathExtension.lowercased()],
                       hunks: diffStore.hunks(for: location, source: source), location: location)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { updateUsage(isActive) }
            .onChange(of: isActive) { _, active in updateUsage(active) }
            .onDisappear { updateUsage(false) }
            .task(id: RemoteCodeDiffID(baseline: baseline, source: source)) {
                diffStore.setBaseline(location: location, source: baseline)
                await diffStore.update(source: source)
            }
    }

    private func updateUsage(_ active: Bool) {
        git.setUsage(id: usageID, listVisible: false, visibleDiffPaths: active ? Set(path.map { [$0] } ?? []) : [])
    }
}

private struct RemoteCodeDiffID: Equatable {
    let baseline: String?
    let source: String
}
