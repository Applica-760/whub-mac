import SwiftUI

struct TabBar: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var showsSelectionBorder = false
    var isCloseDisabled = false
    var closeShortcutEnabled = true
    var notificationDots: [(Color, String)] = []
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
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 2) {
                        ForEach(notificationDots.indices, id: \.self) { index in
                            Circle()
                                .fill(notificationDots[index].0)
                                .frame(width: 7, height: 7)
                        }
                    }
                    .offset(x: 3, y: -3)
                    .allowsHitTesting(false)
                }
                .accessibilityValue(notificationDots.map(\.1).joined(separator: "、"))
            Button("Close \(title)", systemImage: "xmark", action: closeAction)
                .labelStyle(.iconOnly)
                .keyboardShortcut(
                    isSelected && closeShortcutEnabled
                        ? KeyboardShortcut("w", modifiers: .command)
                        : nil
                )
                .disabled(isCloseDisabled)
        }
    }
}
