import SwiftUI
import SwiftData
import WhubAgent
import WhubCore

struct AgentBookOptionControlView: View {
    @ObservedObject var store: AgentStore
    let canChangeKind: Bool
    let changeKind: (AgentKind) -> Void
    let hosts: [WhubCore.Host]
    let hostsError: String?
    let canChangeHost: Bool
    let changeHost: (WhubCore.Host) -> Void
    let isHostConnected: (WhubCore.Host) -> Bool
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
                if let hostsError {
                    Text(hostsError)
                } else if hosts.isEmpty {
                    Text("登録されたホストはありません。")
                }
                ForEach(hosts, id: \.persistentModelID) { host in
                    Button {
                        if isActive && canChangeHost && isHostConnected(host) { changeHost(host) }
                    } label: {
                        if host.persistentModelID == store.target.host?.persistentModelID {
                            Label(host.name, systemImage: "checkmark")
                        } else {
                            Text(host.name)
                        }
                    }
                    .disabled(!isActive || !canChangeHost || !isHostConnected(host)
                              || host.persistentModelID == store.target.host?.persistentModelID)
                }
            } label: {
                Image(systemName: store.target.systemImage)
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 32, height: 32)
            .glassEffect(.regular, in: .circle)
            .disabled(!isActive)
            .accessibilityLabel("ホストを選択")
            .accessibilityValue(store.target.host?.name ?? "ローカル")
            .help(store.target.host?.name ?? "ローカル")

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
