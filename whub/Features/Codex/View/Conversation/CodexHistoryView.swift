import SwiftUI

struct CodexHistoryView: View {
    let turns: [CodexTurn]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("作業履歴").font(.headline)
                ForEach(turns) { turn in
                    if !turn.history.isEmpty {
                        Text(turn.displayPrompt).font(.callout.weight(.semibold)).lineLimit(2)
                        ForEach(turn.history) { item in
                            DisclosureGroup {
                                ScrollView(.horizontal) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if item.type == "commandExecution" { Text(item.displayTitle).bold() }
                                        Text(item.displayText.isEmpty ? "出力なし" : item.displayText)
                                    }
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.vertical, 8)
                                }
                            } label: {
                                Label(item.displayTitle, systemImage: item.status == "failed" ? "xmark.circle" : "terminal")
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
