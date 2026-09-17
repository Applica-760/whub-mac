import SwiftUI

struct TabBar: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var isCloseDisabled = false
    let action: () -> Void
    let closeAction: () -> Void

    var body: some View {
        Group {
            if isSelected {
                controls.buttonStyle(.borderedProminent)
            } else {
                controls.buttonStyle(.bordered)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controls: some View {
        ControlGroup {
            Button(title, systemImage: systemImage, action: action)
                .labelStyle(.titleAndIcon)
            Button("Close \(title)", systemImage: "xmark", action: closeAction)
                .labelStyle(.iconOnly)
                .keyboardShortcut(
                    isSelected
                        ? KeyboardShortcut("w", modifiers: [.command, .shift])
                        : nil
                )
                .disabled(isCloseDisabled)
        }
    }
}

#Preview {
    TabBar(
        title: "Terminal 1",
        systemImage: "terminal",
        isSelected: true,
        action: {},
        closeAction: {}
    )
}
