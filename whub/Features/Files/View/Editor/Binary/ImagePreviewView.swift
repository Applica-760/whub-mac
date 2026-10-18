import SwiftUI

struct ImagePreviewView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
