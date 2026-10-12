import SwiftUI

struct CodexTabBar: View {
    let sessions: [CodexStore]
    let selection: CodexStore.ID
    let completedSessionIDs: Set<CodexStore.ID>
    let select: (CodexStore.ID) -> Void
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func visibleRange(count: Int, selectedIndex: Int) -> Range<Int> {
        let start = min(max(0, selectedIndex - 1), max(0, count - 3))
        return start..<min(count, start + 3)
    }

    var body: some View {
        let selectedIndex = sessions.firstIndex { $0.id == selection } ?? 0
        let range = Self.visibleRange(count: sessions.count, selectedIndex: selectedIndex)
        let visible = Array(sessions.enumerated()).filter { range.contains($0.offset) }
        ZStack {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 16)
                    ForEach(visible, id: \.element.id) { _, session in
                        let selected = session.id == selection
                        ZStack {
                            if selected {
                                Circle().fill(.clear)
                                    .frame(width: 32, height: 32)
                                    .glassEffect(.regular, in: .circle)
                                    .glassEffectID("selection", in: glassNamespace)
                                    .matchedGeometryEffect(id: "selection", in: glassNamespace)
                            } else {
                                Circle().fill(.clear)
                                    .frame(width: 24, height: 24)
                                    .glassEffect(.regular, in: .circle)
                                    .glassEffectID(session.id, in: glassNamespace)
                            }
                        }
                        .frame(width: 32, height: 36)
                    }
                    Color.clear.frame(width: 16)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(0)

            // Keep labels outside the glass container so the material cannot blur them.
            HStack(spacing: 6) {
                overflow(0..<range.lowerBound)
                ForEach(visible, id: \.element.id) { index, session in
                    CodexRoundTab(session: session, number: index + 1,
                                  isSelected: session.id == selection,
                                  hasCompleted: completedSessionIDs.contains(session.id)) {
                        select(session.id)
                    }
                    .frame(width: 32, height: 36)
                }
                overflow(range.upperBound..<sessions.count)
            }
            .foregroundStyle(.primary)
            .zIndex(1)
        }
        .frame(height: 36)
        .animation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.12), value: selection)
    }

    private func overflow(_ range: Range<Int>) -> some View {
        let hasCompleted = range.contains { completedSessionIDs.contains(sessions[$0].id) }
        return Menu {
            ForEach(Array(range), id: \.self) { index in
                Button { select(sessions[index].id) } label: {
                    if completedSessionIDs.contains(sessions[index].id) {
                        Label("Codex \(index + 1)・完了", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("Codex \(index + 1)")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 16)
        .overlay(alignment: .bottomTrailing) {
            if hasCompleted {
                Circle().fill(.green).frame(width: 5, height: 5).allowsHitTesting(false)
            }
        }
        .opacity(range.isEmpty ? 0 : 1)
        .allowsHitTesting(!range.isEmpty)
        .accessibilityHidden(range.isEmpty)
        .accessibilityLabel("隠れた会話を選択")
        .accessibilityValue(hasCompleted ? "完了した応答があります" : "")
        .help(hasCompleted ? "完了した応答があります" : "隠れた会話を選択")
    }
}

private struct CodexRoundTab: View {
    @ObservedObject var session: CodexStore
    let number: Int
    let isSelected: Bool
    let hasCompleted: Bool
    let select: () -> Void

    private var status: (color: Color, label: String)? {
        if !session.requests.isEmpty { return (.orange, "回答・承認待ち") }
        if session.isBusy { return (.blue, "作業中") }
        return hasCompleted ? (.green, "完了") : nil
    }

    var body: some View {
        Button(action: select) {
            Text("\(number)")
                .font(.system(size: isSelected ? 18 : 10, weight: .regular).monospacedDigit())
                .frame(width: isSelected ? 32 : 24, height: isSelected ? 32 : 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if let status {
                CodexStatusBadge(color: status.color,
                                 isRunning: session.isBusy && session.requests.isEmpty,
                                 notificationDate: session.notificationDate)
            }
        }
        .accessibilityLabel("Codex \(number)")
        .accessibilityValue(status?.label ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("Codex \(number)" + (status.map { "・" + $0.label } ?? ""))
    }
}

private struct CodexStatusBadge: View {
    let color: Color
    let isRunning: Bool
    let notificationDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArriving = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30,
                                paused: reduceMotion || (!isRunning && !isArriving))) { context in
            let elapsed = context.date.timeIntervalSince(notificationDate ?? .distantPast)
            let arrival = !isRunning && !reduceMotion && elapsed >= 0 && elapsed < 0.8
            let pulse = (1 + cos(context.date.timeIntervalSinceReferenceDate * .pi)) / 2
            Circle().fill(color)
                .frame(width: 5, height: 5)
                .opacity(isRunning && !reduceMotion ? 0.35 + 0.65 * pulse : 1)
                .scaleEffect(arrival ? 1 + 1.5 * sin(.pi * elapsed / 0.8) : 1)
                .overlay {
                    if arrival {
                        Circle().stroke(color, lineWidth: 1.5)
                            .frame(width: 5 + 24 * elapsed / 0.8,
                                   height: 5 + 24 * elapsed / 0.8)
                            .opacity(1 - elapsed / 0.8)
                    }
                }
        }
        .allowsHitTesting(false)
        .task(id: notificationDate) {
            isArriving = false
            guard let notificationDate else { return }
            let remaining = 0.8 - Date().timeIntervalSince(notificationDate)
            guard remaining > 0 else { return }
            isArriving = true
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            isArriving = false
        }
    }
}
