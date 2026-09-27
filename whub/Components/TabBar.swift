import SwiftUI

struct TabBar: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var showsSelectionBorder = false
    var isCloseDisabled = false
    var closeShortcutEnabled = true
    let action: () -> Void
    let closeAction: () -> Void

    var body: some View {
        Group {
            if isSelected && !showsSelectionBorder {
                controls.buttonStyle(.borderedProminent)
            } else {
                controls.buttonStyle(.bordered)
            }
        }
        .background(
            isSelected && showsSelectionBorder ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            if isSelected && showsSelectionBorder {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
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
                    isSelected && closeShortcutEnabled
                        ? KeyboardShortcut("x", modifiers: [.command, .shift])
                        : nil
                )
                .disabled(isCloseDisabled)
        }
    }
}
