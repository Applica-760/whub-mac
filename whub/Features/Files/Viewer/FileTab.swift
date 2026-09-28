import AppKit
import SwiftUI

struct FileTab: View {
    let title: String
    let icon: Image
    let isSelected: Bool
    let isPreview: Bool
    let titleColor: Color?
    let closeShortcutEnabled: Bool
    let action: () -> Void
    let openAction: () -> Void
    let closeAction: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 4) {
                    icon
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Group {
                        if isPreview { Text(title).italic() }
                        else { Text(title) }
                    }
                    .foregroundStyle(titleColor ?? .primary)
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .simultaneousGesture(TapGesture(count: 2).onEnded(openAction))

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            .keyboardShortcut(
                isSelected && closeShortcutEnabled
                    ? KeyboardShortcut("w", modifiers: .command)
                    : nil
            )
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background(MiddleClickCloseView(action: closeAction))
    }
}

private struct MiddleClickCloseView: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak view, weak coordinator = context.coordinator] event in
            guard let view,
                  event.buttonNumber == 2,
                  event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            coordinator?.action?()
            return nil
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var action: (() -> Void)?
        var monitor: Any?
    }
}
