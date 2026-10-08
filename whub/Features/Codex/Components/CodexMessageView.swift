import AppKit
import SwiftUI

struct CodexMessageView: View {
    let turn: CodexTurn
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("あなた").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(turn.prompt).font(.system(size: 15)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup(isExpanded: $showsHistory) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(turn.history) { item in
                        DisclosureGroup {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 10) {
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
                    }
                }.padding(.vertical, 10)
            } label: {
                HStack(spacing: 8) {
                    if turn.status == "inProgress" { ProgressView().controlSize(.small) }
                    Text("作業履歴 · \(turn.history.count)件")
                }.foregroundStyle(.secondary)
            }

            if !turn.answers.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("回答", systemImage: "text.bubble.fill")
                            .font(.headline).foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("コピー", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(turn.answers.map(\.text).joined(separator: "\n\n"), forType: .string)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                    ForEach(turn.answers) { item in CodexMarkdownResponseView(source: item.text) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                        .fill(Color.accentColor).frame(width: 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            } else if turn.status == "inProgress" {
                Text("回答はここに表示されます。")
                    .font(.callout).foregroundStyle(.tertiary).padding(.vertical, 12)
            }
        }
    }
}
