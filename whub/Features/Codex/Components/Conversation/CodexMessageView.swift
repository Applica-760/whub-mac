import AppKit
import SwiftUI

struct CodexMessageView: View {
    let block: CodexMarkdownResponseView.Block
    let isUser: Bool
    let showsHeader: Bool
    var images: [CodexImageAttachment] = []
    var width: CGFloat? = nil
    var history: [CodexTurn] = []
    @State private var showsHistory = false
    var copy: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader && !isUser {
                HStack {
                    Text("Codex")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    ZStack {
                        if history.contains(where: { $0.status == "inProgress" }) {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("応答を生成中")
                        }
                    }
                    .frame(width: 16, height: 16)
                    Button("作業履歴", systemImage: "terminal") { showsHistory.toggle() }
                        .font(.caption).buttonStyle(.plain)
                        .popover(isPresented: $showsHistory) { CodexHistoryView(turns: history) }
                    Button("回答をコピー", systemImage: "doc.on.doc", action: copy)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .background(CodexSelectionExclusion())
            }
            if images.isEmpty || !block.text.characters.isEmpty || !block.children.isEmpty {
                CodexMarkdownResponseView.BlockView(block: block, width: width.map { $0 - (isUser ? 24 : 0) })
            }
            ForEach(images) { image in
                Image(nsImage: image.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: max(1, (width ?? 280) - 24), height: 80, alignment: .leading)
                    .accessibilityLabel("送信した画像")
            }
        }
        .padding(isUser ? 12 : 0)
        .background(isUser ? Color.secondary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .textSelection(.enabled)
    }
}

struct CodexHistoryView: View {
    let turns: [CodexTurn]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("作業履歴").font(.headline)
                ForEach(turns) { turn in
                    if !turn.history.isEmpty {
                        Text(turn.prompt).font(.callout.weight(.semibold)).lineLimit(2)
                        ForEach(turn.history) { item in
                            DisclosureGroup {
                                ScrollView(.horizontal) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if item.type == "commandExecution" { Text(item.title).bold() }
                                        Text(item.text.isEmpty ? "出力なし" : item.text)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.vertical, 8)
                                }
                            } label: {
                                Label(item.title, systemImage: item.status == "failed" ? "xmark.circle" : "terminal")
                                    .lineLimit(2)
                            }
                            .focusEffectDisabled()
                        }
                    }
                }
            }.padding(20)
        }
        .frame(width: 480, height: 440)
    }
}
