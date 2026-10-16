import AppKit
import SwiftUI

struct AgentBookExchangeView: View {
    let exchange: AgentExchange
    let agentName: String
    let isActive: Bool
    @State private var showsHistory = false

    var body: some View {
        HStack {
            Text(agentName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            ZStack {
                if exchange.status == .running {
                    ProgressView().controlSize(.mini).accessibilityLabel("応答を生成中")
                }
            }
            .frame(width: 16, height: 16)
            Button("作業履歴", systemImage: "terminal") { showsHistory.toggle() }
                .font(.caption).buttonStyle(.plain)
                .popover(isPresented: $showsHistory) { history }
            Button("回答をコピー", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(exchange.answers.map(\.agentBookMarkdown).joined(separator: "\n\n"), forType: .string)
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .onChange(of: isActive) { _, active in
            if !active { showsHistory = false }
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("作業履歴").font(.headline)
                if !exchange.history.isEmpty {
                    Text(exchange.input.agentBookPrompt).font(.callout.weight(.semibold)).lineLimit(2)
                    ForEach(exchange.history) { output in
                        AgentBookOutputView(output: output)
                    }
                }
            }.padding(20)
        }
        .frame(width: 480, height: 440)
    }
}
