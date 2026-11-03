import AppKit
import Combine
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
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity

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
        .task(id: CodeDiffID(baseline: diffStore.baseline, source: source, isActive: diffStore.isActive,
                            isLoadingBaseline: diffStore.isLoadingBaseline)) {
            guard activity?.isActive.value ?? isActive else { return }
            await diffStore.update(source: source)
        }
    }
}

private struct CodeDiffID: Equatable {
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
