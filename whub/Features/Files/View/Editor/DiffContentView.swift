import Combine
import SwiftUI
import SwiftData
import WhubClient
import WhubGit

struct LocalDiffView: View {
    @EnvironmentObject private var editor: EditorStore
    let fileURL: URL

    var body: some View {
        Group {
            if let state = editor.local.diffStores[fileURL] {
                LocalDiffContentView(state: state)
            } else {
                Text("Select a file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(FileLocation.local(fileURL))
    }
}

private struct LocalDiffContentView: View {
    @ObservedObject var state: LocalDiffStore
    @State private var usageID = UUID()
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity

    var body: some View {
        VStack(spacing: 8) {
            if let warning = state.watchError { Text(warning).foregroundStyle(.orange) }
            if let error = state.errorMessage {
                ContentUnavailableView("差分を取得できません", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let diff = state.diff {
                switch diff.content {
                case let .text(before, after):
                    if diff.change == nil { Text("未コミットの差分はありません").foregroundStyle(.secondary) }
                    DiffView(before: before, after: after, fileURL: diff.fileURL, isCurrent: !state.needsRefresh)
                case let .unsupported(reason):
                    ContentUnavailableView("テキスト比較の対象外", systemImage: "doc.badge.ellipsis",
                                           description: Text(UnsupportedDiffMessage.text(reason)))
                }
            } else {
                ProgressView("差分を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.isLoading, state.diff != nil, state.errorMessage == nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .accessibilityLabel("差分を更新中")
                    .allowsHitTesting(false)
            }
        }
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(isActive).eraseToAnyPublisher()) {
            state.setUsage(id: usageID, active: $0)
        }
        .onDisappear { state.setUsage(id: usageID, active: false) }
    }
}

struct RemoteDiffView: View {
    @EnvironmentObject private var files: FilesStore
    let hostID: PersistentIdentifier
    let path: String

    private var location: FileLocation { .remote(hostID: hostID, path: path) }

    var body: some View {
        Group {
            if let root = files.explorer.selectedLocation, let git = files.git.remoteGitStores[root] {
                RemoteDiffContentView(git: git, location: location)
            } else {
                Text("Select a file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(location)
    }
}

private struct RemoteDiffContentView: View {
    @ObservedObject var git: RemoteGitStore
    let location: FileLocation
    @State private var usageID = UUID()
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity

    private var path: String {
        let prefix = git.root.path == "/" ? "/" : git.root.path + "/"
        return location.path.hasPrefix(prefix) ? String(location.path.dropFirst(prefix.count)) : location.path
    }

    var body: some View {
        VStack(spacing: 8) {
            if !git.isConnected {
                ContentUnavailableView("接続されていません", systemImage: "network.slash")
            } else if let error = git.watchError {
                ContentUnavailableView("差分を取得できません", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                Button("再試行") { git.retry() }
            } else if let error = git.errorMessage {
                ContentUnavailableView("差分を取得できません", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let diff = git.diffs[path] {
                if diff.content.type == "text", let before = diff.content.before, let after = diff.content.after {
                    if diff.change == nil { Text("未コミットの差分はありません").foregroundStyle(.secondary) }
                    DiffView(before: before, after: after, fileURL: URL(fileURLWithPath: location.path))
                } else {
                    ContentUnavailableView("テキスト比較の対象外", systemImage: "doc.badge.ellipsis",
                                           description: Text(UnsupportedDiffMessage.text(diff.content.reason)))
                }
            } else {
                ProgressView("差分を読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if git.isLoading, git.isConnected, git.watchError == nil, git.errorMessage == nil, git.diffs[path] != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .accessibilityLabel("差分を更新中")
                    .allowsHitTesting(false)
            }
        }
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(isActive).eraseToAnyPublisher()) { updateUsage($0) }
        .onDisappear { updateUsage(false) }
    }

    private func updateUsage(_ active: Bool) {
        git.setUsage(id: usageID, listVisible: false, visibleDiffPaths: active ? [path] : [])
    }
}

private enum UnsupportedDiffMessage {
    static func text(_ reason: WhubGit.FileDiff.UnsupportedReason) -> String {
        switch reason {
        case .binary: text("binary")
        case .conflict: text("conflict")
        case .submodule: text("submodule")
        case .symbolicLink: text("symbolicLink")
        case .fileType: text("fileType")
        }
    }

    static func text(_ reason: String?) -> String {
        switch reason {
        case "binary": "バイナリまたはUTF-8以外のファイルです。"
        case "conflict": "競合中のファイルです。競合を解消してから再読み込みしてください。"
        case "submodule": "サブモジュールの比較には対応していません。"
        case "symbolicLink": "シンボリックリンクの比較には対応していません。"
        case "fileType": "通常ファイル以外の比較には対応していません。"
        default: "このファイルの比較には対応していません。"
        }
    }
}
