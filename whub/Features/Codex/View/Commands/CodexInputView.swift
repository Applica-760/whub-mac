import AppKit
import SwiftUI

struct CodexInputToken: Equatable {
    let range: NSRange
    let text: String

    static func at(_ selection: NSRange, in source: String) -> Self? {
        let text = source as NSString
        guard selection.length == 0, selection.location >= 0, selection.location <= text.length else { return nil }
        var start = selection.location
        while start > 0, !(UnicodeScalar(text.character(at: start - 1)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) {
            start -= 1
        }
        let token = text.substring(with: NSRange(location: start, length: selection.location - start))
        var end = selection.location
        while end < text.length, !(UnicodeScalar(text.character(at: end)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false) {
            end += 1
        }
        let range = NSRange(location: start, length: end - start)
        guard token.hasPrefix("$") || (token.hasPrefix("/") && text.substring(to: start).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return nil }
        return Self(range: range, text: token)
    }
}

struct CodexInputView: View {
    @EnvironmentObject private var store: CodexStore
    @ObservedObject var commands: CodexCommandsStore
    @EnvironmentObject private var tabsStore: CodexTabsStore
    let focus: CodexBookFocus
    let newConversation: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var candidateIndex = 0
    @State private var dismissedToken: CodexInputToken?
    @State private var showsSkills = false
    @State private var dismissedResume = false
    @State private var dismissedModel = false
    @State private var selectedModel: CodexModel?

    private var token: CodexInputToken? { CodexInputToken.at(selection, in: store.draft) }
    static func isResumeInput(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == CodexCommand.resume.rawValue
    }

    static func isModelInput(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == CodexCommand.model.rawValue
    }

    private var showsModel: Bool { Self.isModelInput(store.draft) && !dismissedModel }
    private var modelChoiceCount: Int { selectedModel?.efforts.count ?? commands.models.count }
    private var showsResume: Bool { Self.isResumeInput(store.draft) && !dismissedResume }
    private var candidates: [(name: String, detail: String, skill: CodexSkill?, thread: CodexRecentThread?)] {
        if showsModel { return [] }
        if showsResume {
            var entries = commands.recentThreads.map {
                (name: $0.title, detail: $0.directory + " · " + $0.updatedAt.formatted(date: .abbreviated, time: .shortened),
                 skill: Optional<CodexSkill>.none, thread: Optional($0))
            }
            if commands.nextThreadCursor != nil { entries.append(("さらに読み込む", "", nil, nil)) }
            return entries
        }
        if showsSkills {
            return commands.skills.map { ("$" + $0.name, $0.description, $0, nil) }
        }
        guard let token, token != dismissedToken else { return [] }
        if token.text.hasPrefix("/") {
            return CodexCommand.allCases.filter { $0.rawValue.hasPrefix(token.text.lowercased()) }.map { ($0.rawValue, $0.description, nil, nil) }
        }
        return commands.skills.filter { ("$" + $0.name).lowercased().hasPrefix(token.text.lowercased()) }
            .map { ("$" + $0.name, $0.description, $0, nil) }
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                imageAttachments()
                if showsModel {
                    CodexModelPicker(commands: commands, session: store, selectedModel: selectedModel,
                                     selectedIndex: candidateIndex, accept: acceptModel) {
                        selectedModel = nil
                        candidateIndex = 0
                    }
                } else if showsResume || showsSkills || (token?.text.hasPrefix("$") == true && token != dismissedToken) || !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if showsResume {
                            if commands.isLoadingThreads { Text("会話を読み込み中…").foregroundStyle(.secondary) }
                            if tabsStore.isResuming { Text("会話を再開中…").foregroundStyle(.secondary) }
                            if let error = commands.threadListError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await commands.loadRecentThreads(directory: store.directory, more: commands.nextThreadCursor != nil) } }
                            }
                            if let error = tabsStore.resumeError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if candidates.isEmpty && !commands.isLoadingThreads && commands.threadListError == nil {
                                Text("再開できる会話はありません").foregroundStyle(.secondary)
                            }
                        } else {
                            if commands.isLoadingSkills { Text("Skillを読み込み中…").foregroundStyle(.secondary) }
                            if let error = commands.skillError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await commands.loadSkills(directory: store.directory, forceReload: true) } }
                            }
                            if candidates.isEmpty && !commands.isLoadingSkills && commands.skillError == nil {
                                Text("該当するSkillはありません").foregroundStyle(.secondary)
                            }
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(candidates.indices, id: \.self) { index in
                                        Button { acceptCandidate(index) } label: {
                                            HStack {
                                                if showsResume {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(candidates[index].name).fontWeight(.medium).lineLimit(1)
                                                        Text(candidates[index].detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                    }
                                                } else {
                                                    Text(candidates[index].name).fontWeight(.medium)
                                                    Text(candidates[index].detail).foregroundStyle(.secondary).lineLimit(1)
                                                }
                                                Spacer()
                                            }
                                            .padding(6)
                                            .contentShape(Rectangle())
                                            .background(index == candidateIndex ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(showsResume && (tabsStore.isResuming || commands.isLoadingThreads))
                                        .accessibilityValue(index == candidateIndex ? "選択中" : "")
                                        .id(index)
                                    }
                                }
                            }
                            .onChange(of: candidateIndex) { _, index in proxy.scrollTo(index) }
                        }
                        .frame(maxHeight: 160)
                    }
                    .font(.callout)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    CodexTextInput(focus: focus, text: $store.draft, selection: $selection, handleKey: handleKey,
                                   pasteImages: store.addImages)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .accessibilityAction(named: Text("送信")) { submit() }
                    ZStack {
                        Color.clear
                        if store.isBusy {
                            Button(store.isStopping ? "停止中…" : "停止", systemImage: "stop.fill") {
                                Task { await store.interrupt() }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: Circle())
                            .contentShape(Circle())
                            .help(store.isStopping ? "停止中…" : "停止")
                            .disabled(store.isStopping)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: 868)
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8)
        .task(id: store.directory) { await commands.loadSkills(directory: store.directory) }
        .onChange(of: token) { _, _ in candidateIndex = 0 }
        .onChange(of: store.directory) { _, _ in store.selectedSkills = [] }
        .onChange(of: store.draft) { _, text in
            dismissedResume = false
            dismissedModel = false
            if !Self.isModelInput(text) { selectedModel = nil }
            if text.isEmpty { showsSkills = false }
        }
        .task(id: showsModel) {
            if showsModel {
                await commands.loadModels(directory: store.directory)
                candidateIndex = commands.models.firstIndex(where: { $0.model == store.model }) ?? 0
            }
        }
        .task(id: showsResume) {
            if showsResume { await commands.loadRecentThreads(directory: store.directory) }
        }
    }

    @ViewBuilder
    private func imageAttachments() -> some View {
        if !store.draftImages.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(store.draftImages.enumerated()), id: \.element.id) { index, attachment in
                        Image(nsImage: attachment.image)
                            .resizable().scaledToFit()
                            .frame(width: 64, height: 64)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("添付画像 \(index + 1)")
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    store.draftImages.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.primary, .background)
                                }
                                .buttonStyle(.plain)
                                .help("画像を削除")
                                .accessibilityLabel("添付画像 \(index + 1)を削除")
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 64)
        }
    }

    private func acceptCandidate(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        let candidate = candidates[index]
        if showsResume {
            guard !tabsStore.isResuming, !commands.isLoadingThreads else { return }
            if let thread = candidate.thread {
                let source = store
                Task {
                    if await tabsStore.resume(thread), Self.isResumeInput(source.draft) {
                        source.draft = ""
                    }
                }
            } else {
                Task { await commands.loadRecentThreads(directory: store.directory, more: true) }
            }
            return
        }
        let range = showsSkills ? selection : token?.range ?? selection
        store.draft = (store.draft as NSString).replacingCharacters(in: range, with: candidate.name + " ")
        selection = NSRange(location: range.location + (candidate.name as NSString).length + 1, length: 0)
        if let skill = candidate.skill, !store.selectedSkills.contains(where: { $0.path == skill.path }) {
            store.selectedSkills.append(skill)
        }
        showsSkills = false
        dismissedToken = nil
    }

    private func acceptModel(_ index: Int) {
        guard !store.isBusy, !store.isResuming, !store.isChangingModel,
              !commands.isLoadingModels, commands.modelError == nil else { return }
        if let selectedModel {
            guard selectedModel.efforts.indices.contains(index) else { return }
            let effort = selectedModel.efforts[index].reasoningEffort
            Task {
                if await commands.applyModel(selectedModel, effort: effort, session: store), Self.isModelInput(store.draft) {
                    store.draft = ""
                    self.selectedModel = nil
                }
            }
        } else {
            guard commands.models.indices.contains(index) else { return }
            let model = commands.models[index]
            selectedModel = model
            let effort = store.model == model.model ? store.settings["effort"] as? String : nil
            candidateIndex = model.efforts.firstIndex(where: { $0.reasoningEffort == (effort ?? model.defaultEffort) }) ?? 0
        }
    }

    private func submit() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = CodexCommand(rawValue: text) else {
            guard store.canSend else { return }
            let skills = store.selectedSkills.filter { $0.isMentioned(in: store.draft) }
            Task { await store.send(skills: skills) }
            return
        }
        if command == .model {
            if dismissedModel { dismissedModel = false }
            else if showsModel { acceptModel(candidateIndex) }
            return
        }
        if command == .resume {
            if dismissedResume {
                dismissedResume = false
            } else if showsResume && !candidates.isEmpty {
                acceptCandidate(min(candidateIndex, candidates.count - 1))
            }
            return
        }
        if command == .new {
            guard !store.isBusy, !store.isResuming, !store.isChangingModel else { return }
            store.draft = ""
            newConversation()
            return
        }
        store.draft = ""
        if command == .skills {
            selection = NSRange(location: 0, length: 0)
            showsSkills = true
        }
        Task { await commands.runCommand(command, session: store) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if [36, 76].contains(event.keyCode), modifiers == .command { submit(); return true }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {
            dismissedToken = token
            dismissedResume = true
            dismissedModel = true
            showsSkills = false
            selectedModel = nil
            candidateIndex = 0
            focus.activateReading()
            return true
        }
        if showsModel {
            guard !commands.isLoadingModels, commands.modelError == nil, !store.isChangingModel,
                  !store.isBusy, !store.isResuming, modelChoiceCount > 0 else {
                return [36, 76, 48, 125, 126].contains(event.keyCode)
            }
            switch event.keyCode {
            case 125: candidateIndex = (candidateIndex + 1) % modelChoiceCount
            case 126: candidateIndex = (candidateIndex + modelChoiceCount - 1) % modelChoiceCount
            case 36, 76: acceptModel(candidateIndex)
            default: return false
            }
            return true
        }
        if showsResume && (commands.isLoadingThreads || tabsStore.isResuming || candidates.isEmpty) {
            return [36, 76, 48, 125, 126].contains(event.keyCode)
        }
        guard !candidates.isEmpty else { return false }
        switch event.keyCode {
        case 125: candidateIndex = (candidateIndex + 1) % candidates.count
        case 126: candidateIndex = (candidateIndex + candidates.count - 1) % candidates.count
        case 36, 76, 48: acceptCandidate(min(candidateIndex, candidates.count - 1))
        default: return false
        }
        return true
    }
}
