import Combine
import SwiftUI
import WhubAgent

struct AgentBookTabButton: View {
    let tabs: [AgentBookTabStore]
    let selection: AgentStore.ID
    let completedSessionIDs: Set<AgentStore.ID>
    let notificationDates: [AgentStore.ID: Date]
    var featureActivity: RetainedPageActivity? = nil
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
                    AgentBookRoundTab(tab: tab, number: index + 1,
                                      isSelected: tab.id == selection,
                                      hasCompleted: completedSessionIDs.contains(tab.id),
                                      notificationDate: notificationDates[tab.id],
                                      featureActivity: featureActivity
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
                        Label("\(tabs[index].store.agentKind.agentBookTabTitle) \(index + 1)・完了", systemImage: "checkmark.circle.fill")
                    } else {
                        Text("\(tabs[index].store.agentKind.agentBookTabTitle) \(index + 1)")
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

private struct AgentBookRoundTab: View {
    @ObservedObject var tab: AgentBookTabStore
    let number: Int
    let isSelected: Bool
    let hasCompleted: Bool
    let notificationDate: Date?
    let featureActivity: RetainedPageActivity?
    let select: () -> Void

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
            ForEach(AgentBookTabPurpose.allCases.prefix(2)) { option in
                Button {
                    tab.purpose = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .labelStyle(.titleAndIcon)
                }
            }
            Divider()
            ForEach(AgentBookTabPurpose.allCases.dropFirst(2)) { option in
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
        .modifier(AgentBookTabStatus(session: tab.store, number: number,
                                     hasCompleted: hasCompleted, notificationDate: notificationDate,
                                     featureActivity: featureActivity))
        .accessibilityLabel("\(tab.store.agentKind.agentBookTabTitle) \(number)・\(purpose?.title ?? "番号表示")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AgentBookTabStatus: ViewModifier {
    @ObservedObject var session: AgentStore
    let number: Int
    let hasCompleted: Bool
    let notificationDate: Date?
    let featureActivity: RetainedPageActivity?

    func body(content: Content) -> some View {
        let waiting = session.exchanges.last(where: { $0.status == .running })?.pendingRequests.isEmpty == false
        let running = session.isBusy && !waiting
        let label = waiting ? "回答・承認待ち" : running ? "作業中" : hasCompleted ? "完了" : ""
        content
            .overlay(alignment: .bottomTrailing) {
                if waiting || running || hasCompleted {
                    AgentBookStatusBadge(color: waiting ? .orange : running ? .blue : .green,
                                         isRunning: running, notificationDate: notificationDate,
                                         featureActivity: featureActivity)
                }
            }
            .accessibilityValue(label)
            .help("\(session.agentKind.agentBookTabTitle) \(number)" + (label.isEmpty ? "" : "・" + label))
    }
}

private struct AgentBookStatusBadge: View {
    let color: Color
    let isRunning: Bool
    let notificationDate: Date?
    let featureActivity: RetainedPageActivity?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @State private var sessionActive = true
    @State private var featureActive = true
    @State private var pulseDimmed = false
    @State private var arrivalScale: CGFloat = 1
    @State private var ringProgress: CGFloat = 1

    private struct AnimationState: Equatable {
        let running: Bool
        let enabled: Bool
        let notificationDate: Date?
    }

    var body: some View {
        let animation = AnimationState(running: isRunning,
                                       enabled: isActive && sessionActive && featureActive && !reduceMotion,
                                       notificationDate: notificationDate)
        Circle().fill(color)
            .frame(width: 10, height: 10)
            .opacity(pulseDimmed ? 0.35 : 1)
            .scaleEffect(arrivalScale)
            .overlay {
                Circle().stroke(color, lineWidth: 1.5)
                    .frame(width: 10 + 24 * ringProgress, height: 10 + 24 * ringProgress)
                    .opacity(1 - ringProgress)
            }
            .allowsHitTesting(false)
            .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) {
                sessionActive = $0
                if !$0 { resetAnimations() }
            }
            .onReceive(featureActivity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) {
                featureActive = $0
                if !$0 { resetAnimations() }
            }
            .task(id: animation) {
                resetAnimations()
                guard animation.enabled else { return }
                await Task.yield()
                guard !Task.isCancelled, activity?.isActive.value != false,
                      featureActivity?.isActive.value != false else { return }
                if animation.running {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                        pulseDimmed = true
                    }
                    return
                }
                guard let date = animation.notificationDate else { return }
                let remaining = 0.8 - Date().timeIntervalSince(date)
                guard remaining > 0 else { return }
                ringProgress = 0
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: remaining)) { ringProgress = 1 }
                withAnimation(.easeOut(duration: remaining / 2)) { arrivalScale = 2.5 }
                do { try await Task.sleep(for: .seconds(remaining / 2)) }
                catch { return }
                withAnimation(.easeIn(duration: remaining / 2)) { arrivalScale = 1 }
            }
            .onDisappear { resetAnimations() }
    }

    private func resetAnimations() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pulseDimmed = false
            arrivalScale = 1
            ringProgress = 1
        }
    }
}

private extension AgentKind {
    var agentBookTabTitle: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        }
    }
}

struct AgentBookToolbar: ToolbarContent {
    @EnvironmentObject private var store: AgentBookStore
    let activate: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            AgentBookTabButton(
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
