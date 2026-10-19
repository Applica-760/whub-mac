import SwiftUI
import WhubAgent

struct AgentBookOptionControlView: View {
    static let inputInset: CGFloat = 270

    @ObservedObject var store: AgentStore
    let canChangeKind: Bool
    let changeKind: (AgentKind) -> Void
    @Environment(\.isRetainedPageActive) private var isActive
    @State private var mockHost = "ローカル"
    private let mockHosts = ["ローカル", "ホスト1", "ホスト2"]

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
                ForEach(mockHosts, id: \.self) { host in
                    Button {
                        if isActive { mockHost = host }
                    } label: {
                        if host == mockHost {
                            Label(host, systemImage: "checkmark")
                        } else {
                            Text(host)
                        }
                    }
                }
            } label: {
                Image(systemName: mockHost == "ローカル" ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .glassEffect(.regular, in: .circle)
            .disabled(!isActive)
            .accessibilityLabel("ホストを選択")
            .accessibilityValue(mockHost)
            .help(mockHost)

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
                let name = (store.selectedModelOption?.displayName ?? "…")
                    .replacingOccurrences(of: "GPT-", with: "", options: .caseInsensitive)
                Text(name)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(width: 85, height: 32)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
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
                let effort = store.selectedModelOption.map { $0.effort ?? "指定なし" } ?? "…"
                Text(effort)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .font(.caption2)
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(width: 85, height: 32)
            .glassEffect(.regular, in: .capsule)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
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
