import QuickLookUI
import SwiftUI
import WhubCore

struct FileViewerView: View {
    var closeShortcutEnabled = true
    @EnvironmentObject private var store: FileViewerStore
    @State private var diffURL: URL?
    @State private var diffHunks: [GitDiffHunk] = []
    @State private var diffErrorMessage: String?

    var body: some View {
        VStack(spacing: 8) {
            if !store.fileURLs.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.fileURLs, id: \.self) { fileURL in
                            let kind = fileKind(for: fileURL)
                            TabBar(
                                title: fileURL.lastPathComponent,
                                systemImage: kind.systemImage,
                                isSelected: fileURL == store.selectedFileURL,
                                closeShortcutEnabled: closeShortcutEnabled,
                                action: {
                                    store.select(fileURL)
                                },
                                closeAction: {
                                    store.close(fileURL)
                                }
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if let diffErrorMessage {
                Text(diffErrorMessage)
                    .foregroundStyle(.secondary)
            }

            WidgetFrame {
                if let selectedFileURL = store.selectedFileURL {
                    if let language = fileKind(for: selectedFileURL).language {
                        CodeViewerView(
                            fileURL: selectedFileURL,
                            language: language,
                            hunks: diffURL == selectedFileURL ? diffHunks : []
                        )
                    } else {
                        QuickLookPreviewView(fileURL: selectedFileURL)
                    }
                } else {
                    Text("Select a file")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .task(id: store.selectedFileURL) {
            diffURL = nil
            diffHunks = []
            diffErrorMessage = nil
            guard let fileURL = store.selectedFileURL, fileKind(for: fileURL).language != nil else { return }
            do {
                let hunks = try await Git.diff(at: fileURL)
                guard !Task.isCancelled else { return }
                diffHunks = hunks
                diffURL = fileURL
            } catch GitError.notRepository {
                return
            } catch {
                guard !Task.isCancelled else { return }
                diffErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct QuickLookPreviewView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let previewView = QLPreviewView(frame: .zero, style: .normal)!
        previewView.previewItem = fileURL as NSURL
        return previewView
    }

    func updateNSView(_ previewView: QLPreviewView, context: Context) {
        previewView.previewItem = fileURL as NSURL
    }
}
