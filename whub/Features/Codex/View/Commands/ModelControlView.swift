import SwiftUI

struct ModelControlView: View {
    @ObservedObject var commands: CodexCommandsStore
    @ObservedObject var session: CodexStore
    @Environment(\.isRetainedPageActive) private var isActive

    private var model: String? { session.settings["model"] as? String ?? commands.configuredModel }
    private var currentModel: CodexModel? {
        commands.models.first { $0.model == model }
    }

    private var effort: String? {
        session.settings["effort"] as? String
            ?? (session.threadID == nil ? commands.configuredEffort : nil)
            ?? currentModel?.defaultEffort
    }
    private var canChange: Bool {
        !session.directory.isEmpty && !session.isBusy && !session.isResuming && !session.isChangingModel
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if commands.isLoadingModels {
                    Text("モデルを読み込み中…")
                } else if let error = commands.modelError {
                    Text(error)
                    Button("再読み込み") { Task { await commands.loadModelControls(directory: session.directory) } }
                } else {
                    ForEach(commands.models) { model in
                        Button {
                            Task { await commands.selectModel(model, session: session) }
                        } label: {
                            if model.model == self.model {
                                Label(model.displayName.replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive), systemImage: "checkmark")
                            } else {
                                Text(model.displayName.replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive))
                            }
                        }
                    }
                    if commands.models.isEmpty { Text("選択できるモデルはありません。") }
                    Divider()
                    Button("再読み込み") { Task { await commands.loadModelControls(directory: session.directory) } }
                }
            } label: {
                Text((currentModel?.displayName ?? model ?? "…").replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.horizontal, 8)
            .frame(width: 104, height: 32)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .disabled(!canChange)
            .accessibilityLabel("モデルを選択")
            .help(model ?? "モデル設定を読み込み中")

            Menu {
                if let currentModel {
                    ForEach(currentModel.efforts) { option in
                        Button {
                            Task { await commands.applyModel(currentModel, effort: option.reasoningEffort, session: session) }
                        } label: {
                            if option.reasoningEffort == effort {
                                Label(option.reasoningEffort, systemImage: "checkmark")
                            } else {
                                Text(option.reasoningEffort)
                            }
                        }
                        .help(option.description)
                    }
                }
            } label: {
                Text(effort ?? "…").lineLimit(1).frame(maxWidth: .infinity)
                    .padding(.trailing, 12)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(.caption2)
            .padding(.horizontal, 6)
            .frame(width: 104, height: 32)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .disabled(!canChange || commands.isLoadingModels || commands.modelError != nil || currentModel == nil)
            .accessibilityLabel("Effortを選択")
            .help("Effort: \(effort ?? "読み込み中")")
        }
        .font(.caption)
        .task(id: isActive ? "\(session.directory):\(commands.generationID)" : "") {
            if isActive && !session.directory.isEmpty {
                await commands.loadModelControls(directory: session.directory)
            }
        }
    }
}
