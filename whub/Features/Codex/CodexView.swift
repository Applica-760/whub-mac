import AppKit
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexStore
    @EnvironmentObject private var files: FileViewerStore
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            CodexHeaderView {
                if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
            }
            Divider().padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        ForEach(store.turns) { turn in
                            CodexTurnView(turn: turn).id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .onChange(of: store.turns.count) { _, _ in
                    if let id = store.turns.last?.id { proxy.scrollTo(id, anchor: .top) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !store.turns.isEmpty {
                        Button("最新へ", systemImage: "arrow.down") {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .buttonStyle(.glass)
                        .padding(12)
                    }
                }
            }
            if !store.requests.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.requests) { request in
                            CodexRequestView(request: request) { store.answer(request, result: $0) }
                        }
                    }.padding(12)
                }
                .frame(maxHeight: 260)
                .background(.orange.opacity(0.08))
            }
            if let error = store.errorMessage {
                DisclosureGroup {
                    Text(error).textSelection(.enabled).font(.callout)
                } label: {
                    Label(String(error.prefix(160)), systemImage: "exclamationmark.triangle")
                        .lineLimit(2)
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
            CodexComposerView {
                if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .navigationTitle("Codex")
        .onAppear {
            if store.directory.isEmpty { store.directory = files.gitRootURL?.path ?? NSHomeDirectory() }
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset() }
        } message: {
            Text("この画面の会話をクリアします。MVPでは過去の会話を選び直す機能はありません。")
        }
    }

}
