import AppKit
import SwiftUI
import WhubCore

struct FileViewerView: View {
    var closeShortcutEnabled = true
    @EnvironmentObject private var store: FileViewerStore

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
                                isPreview: fileURL == store.previewFileURL,
                                titleColor: titleColor,
                                closeShortcutEnabled: closeShortcutEnabled,
                                action: {
                                    store.select(fileURL)
                                },
                                openAction: {
                                    store.open(fileURL)
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
                if let fileURL = store.selectedFileURL, let state = store.fileStates[fileURL] {
                    FileContent(state: state)
                } else {
                    Text("Select a file")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
    }
}

private struct FileContent: View {
    @ObservedObject var state: FileState

    var body: some View {
        switch state.content {
        case let .text(source):
            CodeViewerView(fileURL: state.fileURL, source: source, refreshID: 0)
        case .binary:
            BinaryViewerView(fileURL: state.fileURL)
        case let .error(message):
            Text(message).foregroundStyle(.secondary)
        }
    }
}
