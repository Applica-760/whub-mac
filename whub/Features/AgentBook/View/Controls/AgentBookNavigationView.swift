import Combine
import SwiftUI

struct AgentBookNavigationView: View {
    static let rowHeight: CGFloat = 32

    @Binding var spread: Int
    let pageCount: Int
    let isGenerating: Bool
    let focus: AgentBookFocus
    let featureActivity: RetainedPageActivity?
    @Environment(\.isRetainedPageActive) private var isActive
    @Environment(\.retainedPageActivity) private var activity
    @State private var sessionActive = true
    @State private var featureActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var continuationRevision = 0

    private var canInteract: Bool { isActive && sessionActive && featureActive }

    private var canGoBack: Bool { spread > 0 }
    private var canGoForward: Bool { spread < pageCount - 1 }
    private var firstPage: Int { spread + 1 }
    private var backLabel: String { "前のページ" }
    private var forwardLabel: String { "次のページ" }

    var body: some View {
        HStack(spacing: 0) {
            Button { move(-1) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16))
                        .foregroundStyle(canGoBack ? .primary : .tertiary)
                    Text(canGoBack ? "\(firstPage - 1)" : "-")
                        .font(.system(size: 16).monospacedDigit())
                        .frame(minWidth: 24)
                        .contentTransition(.numericText())
                }
                .frame(width: 54, height: Self.rowHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canInteract || !canGoBack)
            .accessibilityLabel(backLabel)
            .accessibilityValue(canGoBack ? "\(firstPage - 1) / \(pageCount) ページ" : "前のページなし")
            .help(backLabel)

            Divider().frame(height: 16)

            Button { move(1) } label: {
                HStack(spacing: 8) {
                    Text(canGoForward ? "\(firstPage + 1)" : "-")
                        .font(.system(size: 16).monospacedDigit())
                        .frame(minWidth: 24)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16))
                        .foregroundStyle(canGoForward ? .primary : .tertiary)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : continuationRevision)
                }
                .frame(width: 54, height: Self.rowHeight)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canInteract || !canGoForward)
            .accessibilityLabel(forwardLabel)
            .accessibilityValue(canGoForward ? "\(firstPage + 1) / \(pageCount) ページ" : "次のページなし")
            .help(forwardLabel)
        }
        .glassEffect(.regular, in: .capsule)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: spread)
        .onReceive(activity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { sessionActive = $0 }
        .onReceive(featureActivity?.isActive.eraseToAnyPublisher() ?? Just(true).eraseToAnyPublisher()) { featureActive = $0 }
        .onChange(of: pageCount) { old, new in
            if canInteract && isGenerating && canGoForward
                && new > old {
                continuationRevision += 1
            }
        }
    }
    private func move(_ offset: Int) {
        guard canInteract else { return }
        focus.activateReading()
        spread = min(max(0, spread + offset), max(0, pageCount - 1))
    }
}
