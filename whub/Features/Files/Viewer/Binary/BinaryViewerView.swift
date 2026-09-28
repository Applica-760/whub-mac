import SwiftUI

struct BinaryViewerView: View {
    let fileURL: URL

    var body: some View {
        IconList.image(for: fileURL)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 128, height: 128)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(fileURL.lastPathComponent)
    }
}
