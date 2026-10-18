import SwiftUI
import UniformTypeIdentifiers

struct BinaryView: View {
    let fileURL: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ImagePreviewView(image: image)
            } else {
                IconList.image(for: fileURL)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel(fileURL.lastPathComponent)
        .task(id: fileURL) {
            image = nil
            guard UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .image) == true else { return }
            image = NSImage(contentsOf: fileURL)
        }
    }
}
