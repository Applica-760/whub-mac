import AppKit
import SwiftUI

struct TabBarActions {
    let select: () -> Void
    let close: () -> Void
}

struct TabBarContainer<ID: Hashable & Sendable, Tab: View, Trailing: View>: View {
    let ids: [ID]
    let selection: ID?
    let select: (ID) -> Void
    let close: (ID) -> Void
    let canClose: (ID) -> Bool
    let move: (ID, ID?) -> Void
    let isShortcutTarget: (NSWindow) -> Bool
    @ViewBuilder let tab: (ID, Bool, TabBarActions) -> Tab
    @ViewBuilder var trailing: () -> Trailing

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(x: 0)
    @State private var frames: [ID: CGRect] = [:]
    @State private var viewport = CGSize.zero
    @State private var scrollOffset: CGFloat = 0
    @State private var maximumOffset: CGFloat = 0
    @State private var dragging: ID?
    @State private var draft: [ID]?
    @State private var location = CGPoint.zero
    @State private var grabOffset = CGSize.zero
    @State private var floatingOrigin = CGPoint.zero
    @State private var floatingSize = CGSize.zero
    @State private var dragWidths: [ID: CGFloat] = [:]
    @State private var settling = false
    @GestureState private var gestureActive = false

    private var displayedIDs: [ID] { draft ?? ids }
    private var animation: Animation? { reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.12) }
    private var scrollDirection: Int {
        guard dragging != nil, !settling,
              location.y >= 0, location.y <= viewport.height,
              location.x >= 0, location.x <= viewport.width else { return 0 }
        if location.x < 28 && scrollOffset > 0 { return -1 }
        if location.x > viewport.width - 28 && scrollOffset < maximumOffset { return 1 }
        return 0
    }

    var body: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(displayedIDs, id: \.self) { id in
                            tab(id, id == selection, TabBarActions(
                                select: { select(id) },
                                close: { if canClose(id) { close(id) } }
                            ))
                            .background {
                                if id == selection {
                                    Capsule()
                                        .fill(.clear)
                                        .glassEffect(.regular.tint(.white.opacity(0.15)), in: .capsule)
                                        .glassEffectID(id, in: namespace)
                                        .matchedGeometryEffect(id: "selection", in: namespace)
                                        .allowsHitTesting(false)
                                }
                            }
                            .opacity(dragging == id ? 0 : 1)
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(namespace))
                            } action: { frames[id] = $0 }
                            .simultaneousGesture(reorderGesture(for: id))
                            .id(id)
                        }
                    }
                    .padding(4)
                    .animation(animation, value: displayedIDs)
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollIndicators(.hidden)
                .scrollPosition($position)
                .coordinateSpace(name: namespace)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
                .onScrollGeometryChange(for: ScrollMetrics.self) {
                    ScrollMetrics(
                        offset: $0.contentOffset.x,
                        maximum: max(0, $0.contentSize.width - $0.containerSize.width)
                    )
                } action: { _, metrics in
                    scrollOffset = metrics.offset
                    maximumOffset = metrics.maximum
                }
                .glassEffect(.regular, in: .capsule)
                .overlay(alignment: .topLeading) {
                    if let dragging {
                        tab(dragging, dragging == selection, TabBarActions(select: {}, close: {}))
                            .frame(width: floatingSize.width, height: floatingSize.height)
                            .glassEffect(.regular.tint(.white.opacity(0.15)), in: .capsule)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                            .offset(x: floatingOrigin.x, y: floatingOrigin.y)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }

            trailing()
        }
        .animation(animation, value: selection)
        .background(TabBarKeyMonitor { event in
            guard let window = event.window, isShortcutTarget(window),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers else { return false }
            if key == "w", let selection {
                if canClose(selection) { close(selection) }
                return true
            }
            guard key.count == 1, let digit = Int(key), (1...9).contains(digit) else {
                return false
            }
            if ids.indices.contains(digit - 1) { select(ids[digit - 1]) }
            return true
        })
        .task(id: scrollDirection) {
            let direction = scrollDirection
            guard direction != 0 else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard !settling else { return }
                position.scrollTo(x: min(maximumOffset, max(0, scrollOffset + CGFloat(direction) * 12)))
                updateDraft()
            }
        }
        .onChange(of: ids) { _, _ in
            cancelDrag()
            frames = frames.filter { ids.contains($0.key) }
        }
        .onChange(of: gestureActive) { _, active in
            if !active && !settling { cancelDrag() }
        }
        .onDisappear { cancelDrag() }
    }

    private func reorderGesture(for id: ID) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(namespace))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !settling else { return }
                if dragging == nil {
                    guard let frame = frames[id] else { return }
                    dragging = id
                    draft = ids
                    dragWidths = frames.mapValues(\.width)
                    floatingSize = frame.size
                    grabOffset = CGSize(
                        width: value.startLocation.x - frame.minX,
                        height: value.startLocation.y - frame.minY
                    )
                }
                trackPointer(value.location)
                updateDraft()
            }
            .onEnded { value in
                guard dragging == id, !settling else { return }
                trackPointer(value.location)
                let inside = CGRect(origin: .zero, size: viewport).contains(value.location)
                if inside { updateDraft() } else { draft = ids }
                let order = displayedIDs
                guard let index = order.firstIndex(of: id) else { cancelDrag(); return }
                let target = index + 1 < order.count ? order[index + 1] : nil
                settling = true
                withAnimation(animation, completionCriteria: .removed) {
                    floatingOrigin = CGPoint(x: slotX(at: index, in: order), y: 4)
                } completion: {
                    guard dragging == id, settling else { return }
                    if inside && order != ids { move(id, target) }
                    cancelDrag()
                }
            }
    }

    private func trackPointer(_ point: CGPoint) {
        withTransaction(Transaction(animation: nil)) {
            location = point
            floatingOrigin = CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height)
        }
    }

    private func slotX(at index: Int, in order: [ID]) -> CGFloat {
        4 - scrollOffset + order.prefix(index).reduce(CGFloat.zero) { $0 + (dragWidths[$1] ?? 0) + 4 }
    }

    private func updateDraft() {
        guard let dragging, var order = draft, !settling,
              CGRect(origin: .zero, size: viewport).contains(location),
              let oldIndex = order.firstIndex(of: dragging) else { return }
        let center = floatingOrigin.x + floatingSize.width / 2
        var index = oldIndex
        if index > 0,
           center < slotX(at: index - 1, in: order) + (dragWidths[order[index - 1]] ?? 0) / 2 {
            while index > 0,
                  center < slotX(at: index - 1, in: order) + (dragWidths[order[index - 1]] ?? 0) / 2 {
                order.swapAt(index, index - 1)
                index -= 1
            }
        } else {
            while index + 1 < order.count,
                  center > slotX(at: index + 1, in: order) + (dragWidths[order[index + 1]] ?? 0) / 2 {
                order.swapAt(index, index + 1)
                index += 1
            }
        }
        draft = order
    }

    private func cancelDrag() {
        dragging = nil
        draft = nil
        settling = false
        dragWidths = [:]
    }
}

private struct ScrollMetrics: Equatable {
    let offset: CGFloat
    let maximum: CGFloat
}

private struct TabBarKeyMonitor: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak view, weak coordinator = context.coordinator] event in
            guard let view, let coordinator,
                  let window = view.window, window.isKeyWindow,
                  event.window === window, !view.isHiddenOrHasHiddenAncestor,
                  coordinator.handle?(event) == true else { return event }
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var handle: ((NSEvent) -> Bool)?
        var monitor: Any?
    }
}
