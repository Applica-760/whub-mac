import SwiftUI

struct CodexModelPicker: View {
    @ObservedObject var commands: CodexCommandsStore
    @ObservedObject var session: CodexStore
    let selectedModel: CodexModel?
    let selectedIndex: Int
    let accept: (Int) -> Void
    let back: () -> Void

    private var choices: [(String, String)] {
        if let selectedModel {
            return selectedModel.efforts.map {
                let current = session.model == selectedModel.model && session.settings["effort"] as? String == $0.reasoningEffort
                return ($0.reasoningEffort + (current ? " (current)" : $0.reasoningEffort == selectedModel.defaultEffort ? " (default)" : ""), $0.description)
            }
        }
        return commands.models.map { ($0.displayName + ($0.model == session.model ? " (current)" : ""), $0.description) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selectedModel.map { "Select Reasoning Level for \($0.displayName)" } ?? "Select Model").fontWeight(.medium)
            Text("Current: \(session.model) · This session only").foregroundStyle(.secondary)
            if commands.isLoadingModels { Text("モデルを読み込み中…") }
            if session.isChangingModel { Text("モデルを変更中…") }
            if session.isBusy || session.isResuming { Text("作業または会話の再開が終わってから変更できます。") }
            if let error = commands.modelError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("再読み込み") { back(); Task { await commands.loadModels(directory: session.directory) } }
            }
            if choices.isEmpty && !commands.isLoadingModels && commands.modelError == nil {
                Text("選択できるモデルはありません。")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(choices.indices, id: \.self) { index in
                            Button { accept(index) } label: {
                                HStack {
                                    Text(choices[index].0).fontWeight(.medium)
                                    Text(choices[index].1).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer()
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(index == selectedIndex ? "選択中" : "")
                            .id(index)
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, index in proxy.scrollTo(index) }
            }
            .frame(maxHeight: 160)
            .disabled(commands.isLoadingModels || commands.modelError != nil || session.isBusy || session.isResuming || session.isChangingModel)
            HStack {
                if selectedModel != nil { Button("モデル一覧に戻る", action: back) }
                Text("↑↓ Select · Enter Apply · Esc Back").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}
