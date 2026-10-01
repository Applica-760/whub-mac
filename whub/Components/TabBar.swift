import AppKit
import SwiftUI

struct TabBar: View {
    let title: String
    let icon: Image
    let isSelected: Bool
    var isPreview = false
    var titleColor: Color?
    var isCloseDisabled = false
    var status: (color: Color, label: String)?
    var openAction: (() -> Void)?
    let action: () -> Void
    let closeAction: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .italic(isPreview)
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(titleColor ?? .primary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(status?.label ?? "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .simultaneousGesture(TapGesture(count: 2).onEnded { openAction?() })

            Button(action: closeAction) {
                Image(systemName: status != nil && !isHovered ? "circle.fill" : "xmark")
                    .font(.system(size: status != nil && !isHovered ? 8 : 12))
                    .foregroundStyle(isHovered ? .primary : status?.color ?? .primary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .accessibilityLabel("Close \(title)")
            .help(status?.label ?? "Close \(title)")
            .disabled(isCloseDisabled)
        }
        .onHover { isHovered = $0 }
        .background(MiddleClickCloseView(action: closeAction, isEnabled: !isCloseDisabled))
    }
}

private struct MiddleClickCloseView: NSViewRepresentable {
    let action: () -> Void
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak view, weak coordinator = context.coordinator] event in
            guard let view, let coordinator,
                  coordinator.isEnabled,
                  !view.isHiddenOrHasHiddenAncestor,
                  event.buttonNumber == 2,
                  event.window === view.window,
                  view.visibleRect.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            coordinator.action?()
            return nil
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var action: (() -> Void)?
        var isEnabled = false
        var monitor: Any?
    }
}
