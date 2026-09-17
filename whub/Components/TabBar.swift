import SwiftUI

struct TabBar: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var button: some View {
        Button(title, systemImage: systemImage, action: action)
    }
}

#Preview {
    TabBar(title: "Terminal 1", systemImage: "terminal", isSelected: true) {}
}
