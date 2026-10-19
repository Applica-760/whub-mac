import SwiftUI
import WhubAgent

struct AgentBookOptionControlView: View {
    static let inputInset: CGFloat = 270

    @ObservedObject var store: AgentStore
    let canChangeKind: Bool
    let changeKind: (AgentKind) -> Void
    @Environment(\.isRetainedPageActive) private var isActive

    private var canChange: Bool {
        isActive && store.isConnected && !store.isBusy && !store.isResuming && !store.isChangingModel
    }

    private var models: [AgentBookModelChoice] {
        var seen = Set<String>()
        return store.modelOptions.compactMap { option in
            guard seen.insert(option.modelID).inserted else { return nil }
            return AgentBookModelChoice(options: store.modelOptions.filter { $0.modelID == option.modelID })
        }
    }

    private var currentModel: AgentBookModelChoice? {
        models.first { $0.id == store.selectedModelOption?.modelID }
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AgentKind.allCases, id: \.self) { kind in
                    Button {
                        if isActive && canChangeKind && store.agentKind != kind { changeKind(kind) }
                    } label: {
                        Label(kind.displayName, image: kind.iconName)
                    }
                    .disabled(!isActive || !canChangeKind || store.agentKind == kind)
                }
            } label: {
                Image(store.agentKind.iconName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .glassEffect(.regular, in: .circle)
            .accessibilityLabel("接続先を選択")
            .help(store.agentKind.displayName)

            Menu {
                if store.isLoadingModelOptions {
                    Text("モデルを読み込み中…")
                } else if let error = store.modelOptionsError {
                    Text(error)
                    Button("再読み込み") { reload() }
                } else {
                    ForEach(models) { model in
                        Button {
                            if let option = model.option(preserving: store.selectedModelOption) {
                                select(option)
                            }
                        } label: {
                            if model.id == store.selectedModelOption?.modelID {
                                Label(model.label, systemImage: "checkmark")
                            } else {
                                Text(model.label)
                            }
                        }
                        .disabled(model.option(preserving: store.selectedModelOption) == nil)
                    }
                    if models.isEmpty { Text("選択できるモデルはありません。") }
                    Divider()
                    Button("再読み込み") { reload() }
                }
            } label: {
                Text((store.selectedModelOption?.displayName ?? "…")
                    .replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive))
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
            .help(store.selectedModelOption?.modelID ?? "モデル設定を読み込み中")

            Menu {
                if let currentModel {
                    ForEach(currentModel.options) { option in
                        Button {
                            select(option)
                        } label: {
                            if option.id == store.selectedModelOption?.id {
                                Label(option.effort ?? "指定なし", systemImage: "checkmark")
                            } else {
                                Text(option.effort ?? "指定なし")
                            }
                        }
                        .help(option.description)
                    }
                }
            } label: {
                Text(store.selectedModelOption.map { $0.effort ?? "指定なし" } ?? "…")
                    .lineLimit(1).frame(maxWidth: .infinity)
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
            .disabled(!canChange || store.isLoadingModelOptions || store.modelOptionsError != nil || currentModel == nil)
            .accessibilityLabel("Effortを選択")
            .help("Effort: \(store.selectedModelOption.map { $0.effort ?? "指定なし" } ?? "読み込み中")")
        }
        .font(.caption)
        .task(id: "\(store.id):\(isActive && store.isConnected && !store.isResuming)") {
            if isActive && store.isConnected && !store.isResuming {
                await store.loadModelOptions()
            }
        }
    }

    private func reload() {
        guard isActive else { return }
        Task { await store.loadModelOptions() }
    }

    private func select(_ option: AgentModelOption) {
        guard canChange else { return }
        Task { await store.changeModel(option) }
    }
}

private struct AgentBookModelChoice: Identifiable {
    let options: [AgentModelOption]
    var id: String { options[0].modelID }
    var label: String {
        options[0].displayName.replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive)
    }

    func option(preserving selected: AgentModelOption?) -> AgentModelOption? {
        if let selected, let match = options.first(where: { $0.effort == selected.effort }) {
            return match
        }
        return options.first { $0.isDefaultEffort }
    }
}
