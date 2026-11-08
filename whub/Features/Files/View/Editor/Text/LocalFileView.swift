import AppKit
import Combine
import SwiftUI

struct LocalFileView: View {
    @EnvironmentObject private var editor: EditorStore
    @EnvironmentObject private var files: FilesStore
    let fileURL: URL
    let editorID: String

    private var location: FileLocation { .local(fileURL) }

    var body: some View {
        Group {
            if let state = editor.local.fileStores[location] {
                LocalFileContentView(state: state, editorID: editorID, refreshID: files.refreshID,
                                     showsMarkdownPreview: editor.markdownPreviews.contains(location)) { [weak editor, location] in
                    editor?.didEdit(location)
                }
            } else {
                Text("Select a file")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .id(location)
    }
}

private struct LocalFileContentView: View {
    @ObservedObject var state: LocalFileStore
    let editorID: String
    let refreshID: Int
    let showsMarkdownPreview: Bool
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let message = state.diskMessage {
                Text(message)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
            if state.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileContent
            }
        }
    }

    @ViewBuilder private var fileContent: some View {
        switch state.document.content {
        case let .text(source):
            MarkdownSplitView(source: source, showsPreview: showsMarkdownPreview) {
                LocalCodeEditorView(fileURL: state.fileURL, source: source, refreshID: refreshID,
                                    state: state, editorID: editorID, onEdit: onEdit)
            }
        case .binary:
            BinaryView(fileURL: state.fileURL)
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}

struct LocalCodeEditorView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    let state: LocalFileStore
    let editorID: String
    let onEdit: () -> Void
    @EnvironmentObject private var gitStore: GitStore
    @StateObject private var diffStore = GitLineStore()
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = diffStore.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
            TextView(
                state: state.document,
                editorID: editorID,
                onEdit: onEdit,
                source: source,
                language: FileKind.resolve(path: fileURL.path).highlightLanguage,
                hunks: diffStore.hunks(for: .local(fileURL), source: source), location: .local(fileURL)
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(isActive).eraseToAnyPublisher()) {
            diffStore.setActive($0)
        }
        .onDisappear { diffStore.setActive(false) }
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID, diskRevision: state.diskRevision,
                            isActive: diffStore.isActive)) {
            guard activity?.isActive.value ?? isActive else { return }
            await diffStore.load(fileURL: fileURL, gitStore: gitStore)
        }
        .task(id: LocalCodeDiffID(baseline: diffStore.baseline, source: source, isActive: diffStore.isActive,
                            isLoadingBaseline: diffStore.isLoadingBaseline)) {
            guard activity?.isActive.value ?? isActive else { return }
            await diffStore.update(source: source)
        }
    }
}

private struct LocalCodeDiffID: Equatable {
    let baseline: GitLineStore.Baseline?
    let source: String
    let isActive: Bool
    let isLoadingBaseline: Bool
}

private struct CodeLoadID: Equatable {
    let fileURL: URL
    let refreshID: Int
    let diskRevision: Int
    let isActive: Bool
}
