import SwiftUI

struct CodexTabBar: View {
    let sessions: [CodexStore]
    let selection: CodexStore.ID
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
                                  isSelected: session.id == selection) {
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
        Menu {
            ForEach(Array(range), id: \.self) { index in
                Button("Codex \(index + 1)") { select(sessions[index].id) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 16)
        .opacity(range.isEmpty ? 0 : 1)
        .allowsHitTesting(!range.isEmpty)
        .accessibilityHidden(range.isEmpty)
        .accessibilityLabel("隠れた会話を選択")
    }
}

private struct CodexRoundTab: View {
    @ObservedObject var session: CodexStore
    let number: Int
    let isSelected: Bool
    let select: () -> Void

    private var status: String {
        !session.requests.isEmpty ? "回答・承認待ち" : session.isBusy ? "作業中" : ""
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
            if !status.isEmpty {
                Circle().fill(session.requests.isEmpty ? Color.blue : .orange)
                    .frame(width: 5, height: 5)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Codex \(number)")
        .accessibilityValue(status)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(status.isEmpty ? "Codex \(number)" : "Codex \(number)・\(status)")
    }
}
