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
                            let titleColor: Color? = switch store.gitChanges[fileURL.standardizedFileURL] {
                            case .added: Color(nsColor: .systemGreen)
                            case .modified, .deleted: Color(nsColor: .systemOrange)
                            case nil: nil
                            }
                            FileTab(
                                title: fileURL.lastPathComponent,
                                systemImage: kind.systemImage,
                                isSelected: fileURL == store.selectedFileURL,
                                titleColor: titleColor,
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
        .task(id: ViewerLoadID(fileURL: store.selectedFileURL, refreshID: store.refreshID)) {
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

private struct ViewerLoadID: Equatable {
    let fileURL: URL?
    let refreshID: Int
}

private struct FileTab: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let titleColor: Color?
    let closeShortcutEnabled: Bool
    let action: () -> Void
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                    Text(title).foregroundStyle(titleColor ?? .primary)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            .keyboardShortcut(
                isSelected && closeShortcutEnabled
                    ? KeyboardShortcut("w", modifiers: [.command, .shift])
                    : nil
            )
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
