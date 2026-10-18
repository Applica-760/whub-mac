import SwiftUI

struct ServerLogView: View {
    @ObservedObject var store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ログ").font(.title3.bold())
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.visibleLogs.isEmpty {
                        Text("操作結果・エラーをここに表示します。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.visibleLogs.reversed()) { entry in
                        HStack(alignment: .top, spacing: 4) {
                            if entry.isError { Image(systemName: "exclamationmark.triangle") }
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) \(entry.environment.rawValue) · \(entry.message)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 180)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.secondary.opacity(0.2))
                    .allowsHitTesting(false)
            }
            HStack(spacing: 5) {
                if let activity = store.activity {
                    ProgressView().controlSize(.small)
                    Text(activity)
                } else {
                    Text("待機中")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

}
