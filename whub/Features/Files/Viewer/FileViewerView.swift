import AppKit
import SwiftUI
import WhubCore

struct FileViewerView: View {
    var closeShortcutEnabled = true
    @EnvironmentObject private var store: FileViewerStore
    @State private var loadedFile: LoadedFile?

    var body: some View {
        VStack(spacing: 8) {
            if !store.fileURLs.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.fileURLs, id: \.self) { fileURL in
                            let titleColor: Color? = switch store.gitChanges[fileURL.standardizedFileURL] {
                            case .added: Color(nsColor: .systemGreen)
                            case .modified, .deleted: Color(nsColor: .systemOrange)
                            case nil: nil
                            }
                            FileTab(
                                title: fileURL.lastPathComponent,
                                icon: IconList.image(for: fileURL),
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

            WidgetFrame {
                FileContent(fileURL: store.selectedFileURL, loadedFile: loadedFile, refreshID: store.refreshID)
                    .id(store.refreshID)
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .task(id: ViewerLoadID(fileURL: store.selectedFileURL, refreshID: store.refreshID)) {
            loadedFile = nil
            guard let fileURL = store.selectedFileURL else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                guard !Task.isCancelled else { return }
                let content = String(data: data, encoding: .utf8).map(LoadedContent.text) ?? .binary
                loadedFile = LoadedFile(fileURL: fileURL, refreshID: store.refreshID, content: content)
            } catch {
                guard !Task.isCancelled else { return }
                loadedFile = LoadedFile(fileURL: fileURL, refreshID: store.refreshID, content: .error(error.localizedDescription))
            }
        }
    }
}

private struct ViewerLoadID: Equatable {
    let fileURL: URL?
    let refreshID: Int
}

private struct LoadedFile {
    let fileURL: URL
    let refreshID: Int
    let content: LoadedContent
}

private enum LoadedContent {
    case text(String)
    case binary
    case error(String)
}

private struct FileContent: View {
    let fileURL: URL?
    let loadedFile: LoadedFile?
    let refreshID: Int

    var body: some View {
        if let fileURL {
            if let loadedFile,
               loadedFile.fileURL == fileURL,
               loadedFile.refreshID == refreshID {
                switch loadedFile.content {
                case let .text(source):
                    CodeViewerView(fileURL: fileURL, source: source, refreshID: refreshID)
                case .binary:
                    BinaryViewerView(fileURL: fileURL)
                case let .error(message):
                    Text(message).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        } else {
            Text("Select a file")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FileTab: View {
    let title: String
    let icon: Image
    let isSelected: Bool
    let titleColor: Color?
    let closeShortcutEnabled: Bool
    let action: () -> Void
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 4) {
                    icon
                        .resizable()
                        .frame(width: 16, height: 16)
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
                    ? KeyboardShortcut("x", modifiers: [.command, .shift])
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
