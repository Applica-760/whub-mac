import SwiftUI
import WhubAgent

struct AgentBook2TabButton: View {
    let tabs: [AgentBook2TabStore]
    let selection: AgentStore.ID
    let completedSessionIDs: Set<AgentStore.ID>
    let notificationDates: [AgentStore.ID: Date]
    let select: (AgentStore.ID) -> Void
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func visibleRange(count: Int, selectedIndex: Int) -> Range<Int> {
        let start = min(max(0, selectedIndex - 2), max(0, count - 5))
        return start..<min(count, start + 5)
    }

    var body: some View {
        let selectedIndex = tabs.firstIndex { $0.id == selection } ?? 0
        let range = Self.visibleRange(count: tabs.count, selectedIndex: selectedIndex)
        let visible = Array(tabs.enumerated()).filter { range.contains($0.offset) }
        ZStack {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 16)
                    ForEach(visible, id: \.element.id) { _, tab in
                        let session = tab.store
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
                ForEach(visible, id: \.element.id) { index, tab in
                    AgentBook2RoundTab(tab: tab, session: tab.store, number: index + 1,
                                      isSelected: tab.id == selection,
                                      hasCompleted: completedSessionIDs.contains(tab.id),
                                      notificationDate: notificationDates[tab.id]
                    ) {
                        select(tab.id)
                    }
                    .frame(width: 32, height: 36)
                }
                overflow(range.upperBound..<tabs.count)
            }
            .foregroundStyle(.primary)
            .zIndex(1)
        }
        .frame(height: 36)
        .animation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.12), value: selection)
    }

    private func overflow(_ range: Range<Int>) -> some View {
        let hasCompleted = range.contains { completedSessionIDs.contains(tabs[$0].id) }
        return Menu {
            ForEach(Array(range), id: \.self) { index in
                Button { select(tabs[index].id) } label: {
                    if completedSessionIDs.contains(tabs[index].id) {
                        Label("\(tabs[index].store.agentKind.agentBook2TabTitle) \(index + 1)・完了", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("\(tabs[index].store.agentKind.agentBook2TabTitle) \(index + 1)")
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

private struct AgentBook2RoundTab: View {
    @ObservedObject var tab: AgentBook2TabStore
    @ObservedObject var session: AgentStore
    let number: Int
    let isSelected: Bool
    let hasCompleted: Bool
    let notificationDate: Date?
    let select: () -> Void

    private var hasPendingRequests: Bool {
        session.exchanges.last(where: { $0.status == .running })?.pendingRequests.isEmpty == false
    }

    private var status: (color: Color, label: String)? {
        if hasPendingRequests { return (.orange, "回答・承認待ち") }
        if session.isBusy { return (.blue, "作業中") }
        return hasCompleted ? (.green, "完了") : nil
    }

    var body: some View {
        let purpose = tab.purpose
        Button(action: select) {
            Group {
                if let purpose {
                    Image(systemName: purpose.symbol)
                        .font(.system(size: isSelected ? 15 : 11, weight: .regular))
                } else {
                    Text("\(number)")
                        .font(.system(size: isSelected ? 18 : 10, weight: .regular).monospacedDigit())
                }
            }
                .frame(width: isSelected ? 32 : 24, height: isSelected ? 32 : 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(AgentBook2TabPurpose.allCases.prefix(2)) { option in
                Button {
                    tab.purpose = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            ForEach(AgentBook2TabPurpose.allCases.dropFirst(2)) { option in
                Button {
                    tab.purpose = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            if purpose != nil {
                Divider()
                Button {
                    tab.purpose = nil
                } label: {
                    Label("表示番号に戻す", systemImage: "number")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let status {
                AgentBook2StatusBadge(color: status.color,
                                 isRunning: session.isBusy && !hasPendingRequests,
                                 notificationDate: notificationDate)
            }
        }
        .accessibilityLabel("\(session.agentKind.agentBook2TabTitle) \(number)・\(purpose?.title ?? "番号表示")")
        .accessibilityValue(status?.label ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(session.agentKind.agentBook2TabTitle) \(number)" + (status.map { "・" + $0.label } ?? ""))
    }
}

private struct AgentBook2StatusBadge: View {
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

private extension AgentKind {
    var agentBook2TabTitle: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

struct AgentBook2Toolbar: ToolbarContent {
    @EnvironmentObject private var store: AgentBook2Store
    let activate: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            AgentBook2TabButton(
                tabs: store.tabs, selection: store.selectedTabID,
                completedSessionIDs: store.completedTabIDs, notificationDates: store.notificationDates
            ) { id in
                store.select(id)
                activate()
            }
            .frame(width: 232, height: 36)
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: .capsule)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.fixed, placement: .primaryAction)
    }
}
