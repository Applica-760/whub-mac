import Combine
import SwiftUI

struct AgentBook2NavigationView: View {
    static let rowHeight: CGFloat = 32

    @Binding var spread: Int
    let pageCount: Int
    let isGenerating: Bool
    let focus: AgentBook2Focus
    let featureActivity: RetainedPageActivity?
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @State private var sessionActive = true
    @State private var featureActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var continuationRevision = 0

    private var canInteract: Bool { isActive && sessionActive && featureActive }

    private var canGoBack: Bool { spread > 0 }
    private var canGoForward: Bool { spread < (pageCount - 1) / 2 }

    var body: some View {
        HStack {
            Button { move(-1) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16))
                        .foregroundStyle(canGoBack ? .primary : .tertiary)
                    Divider().frame(height: 16)
                    Text("\(spread * 2 + 1)")
                        .font(.system(size: 16).monospacedDigit())
                        .frame(minWidth: 24)
                        .contentTransition(.numericText())
                }
                .frame(width: 80, height: Self.rowHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
            .disabled(!canInteract || !canGoBack)
            .accessibilityLabel("前の見開き")
            .accessibilityValue("\(spread * 2 + 1) / \(pageCount) ページ")
            .help("前の見開き")

            Spacer()

            Button { move(1) } label: {
                HStack(spacing: 8) {
                    Text(spread * 2 + 1 < pageCount ? "\(spread * 2 + 2)" : "—")
                        .font(.system(size: 16).monospacedDigit())
                        .frame(minWidth: 24)
                        .contentTransition(.numericText())
                    Divider().frame(height: 16)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16))
                        .foregroundStyle(canGoForward ? .primary : .tertiary)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : continuationRevision)
                }
                .frame(width: 80, height: Self.rowHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
            .disabled(!canInteract || !canGoForward)
            .accessibilityLabel("次の見開き")
            .accessibilityValue(spread * 2 + 1 < pageCount ? "\(spread * 2 + 2) / \(pageCount) ページ" : "右ページなし")
            .help("次の見開き")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 64)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: spread)
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { sessionActive = $0 }
        .onReceive(featureActivity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { featureActive = $0 }
        .onChange(of: pageCount) { old, new in
            if canInteract && isGenerating && canGoForward && (new + 1) / 2 > (old + 1) / 2 {
                continuationRevision += 1
            }
        }
    }
    private func move(_ offset: Int) {
        guard canInteract else { return }
        focus.activateReading()
        spread = min(max(0, spread + offset), max(0, (pageCount - 1) / 2))
    }
}
