import AppKit
import SwiftUI

struct LocalCodeEditorView: View {
    let fileURL: URL
    let source: String
    let refreshID: Int
    let state: LocalFileStore
    let editorID: String
    let onEdit: () -> Void
    @EnvironmentObject private var gitStore: GitStore
    @StateObject private var diffStore = GitLineStore()

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = diffStore.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
            CodeEditorView(
                state: state.document,
                editorID: editorID,
                onEdit: onEdit,
                source: source,
                language: codeLanguages[fileURL.pathExtension.lowercased()],
                hunks: diffStore.hunks(for: .local(fileURL), source: source)
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: CodeLoadID(fileURL: fileURL, refreshID: refreshID, diskRevision: state.diskRevision)) {
            await diffStore.load(fileURL: fileURL, gitStore: gitStore)
        }
        .task(id: CodeDiffID(baseline: diffStore.baseline, source: source)) {
            await diffStore.update(source: source)
        }
    }
}

private struct CodeDiffID: Equatable {
    let baseline: GitLineStore.Baseline?
    let source: String
}

private struct CodeLoadID: Equatable {
    let fileURL: URL
    let refreshID: Int
    let diskRevision: Int
}
