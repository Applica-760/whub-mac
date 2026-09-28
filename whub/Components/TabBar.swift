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
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .labelStyle(.titleAndIcon)
                    ForEach(notificationDots.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(notificationDots[index].0)
                                .frame(width: 6, height: 6)
                            Text(notificationDots[index].1)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(notificationDots[index].0.opacity(0.2), in: Capsule())
                        .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(notificationDots.map(\.1).joined(separator: "、"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button("Close \(title)", systemImage: "xmark", action: closeAction)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
                .keyboardShortcut(
                    isSelected && closeShortcutEnabled
                        ? KeyboardShortcut("w", modifiers: .command)
                        : nil
                )
                .disabled(isCloseDisabled)
        }
        .glassEffect(
            .regular.interactive(),
            in: .capsule
        )
        .overlay {
            if isSelected {
                Capsule()
                    .strokeBorder(Color.accentColor, lineWidth: showsSelectionBorder ? 2 : 1)
                    .allowsHitTesting(false)
            }
        }
    }
}
