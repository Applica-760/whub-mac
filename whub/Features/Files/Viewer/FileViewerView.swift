import QuickLookUI
import SwiftUI

struct FileViewerView: View {
    @EnvironmentObject private var store: FileViewerStore

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
                if let selectedFileURL = store.selectedFileURL {
                    if let language = fileKind(for: selectedFileURL).language {
                        CodeViewerView(fileURL: selectedFileURL, language: language)
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
