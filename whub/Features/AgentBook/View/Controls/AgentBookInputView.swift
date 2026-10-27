import AppKit
import SwiftUI
import WhubAgent

struct AgentBookInputToken: Equatable {
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

struct AgentBookInputView: View {
    @ObservedObject var store: AgentStore
    @ObservedObject var skillStore: AgentSkillStore
    @ObservedObject var historyStore: AgentHistoryStore
    let focus: AgentBookFocus
    var inputFocus: AgentBookFocus? = nil
    let agentName: String
    let newConversation: () -> Void
    let resume: (AgentHistoryEntry) async -> Bool
    var isResuming = false
    var resumeError: String? = nil
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var candidateIndex = 0
    @State private var dismissedToken: AgentBookInputToken?
    @State private var showsSkills = false
    @State private var dismissedResume = false
    @State private var isRequestingResume = false

    private var isOpeningHistory: Bool { isResuming || isRequestingResume }

    private var text: Binding<String> {
        Binding(
            get: { store.draft.agentBookDraftText },
            set: { text in
                let insertion = store.draft.firstIndex { if case .text = $0 { return true }; return false } ?? 0
                store.draft.removeAll {
                    if case .text = $0 { return true }
                    if case .skill(let skill) = $0 { return !skill.agentBookIsMentioned(in: text) }
                    return false
                }
                if !text.isEmpty { store.draft.insert(.text(text), at: min(insertion, store.draft.count)) }
            }
        )
    }

    private var token: AgentBookInputToken? { AgentBookInputToken.at(selection, in: text.wrappedValue) }
    private var showsResume: Bool { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) == AgentSlashCommand.resume.rawValue && !dismissedResume }
    private var candidates: [(name: String, detail: String, skill: AgentSkill?, entry: AgentHistoryEntry?)] {
        if showsResume {
            var entries = historyStore.entries.map {
                (name: $0.agentBookTitle, detail: $0.directory + " · " + $0.updatedAt.formatted(date: .abbreviated, time: .shortened),
                 skill: Optional<AgentSkill>.none, entry: Optional($0))
            }
            if historyStore.nextCursor != nil { entries.append(("さらに読み込む", "", nil, nil)) }
            return entries
        }
        let skills = skillStore.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if showsSkills { return skills.map { ("$" + $0.name, $0.description, $0, nil) } }
        guard let token, token != dismissedToken else { return [] }
        if token.text.hasPrefix("/") {
            return AgentSlashCommand.allCases.filter { $0 != .model && $0.rawValue.hasPrefix(token.text.lowercased()) }
                .map { ($0.rawValue, $0.agentBookDescription, nil, nil) }
        }
        return skills.filter { ("$" + $0.name).lowercased().hasPrefix(token.text.lowercased()) }
            .map { ("$" + $0.name, $0.description, $0, nil) }
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                imageAttachments()
                if showsResume || showsSkills || (token?.text.hasPrefix("$") == true && token != dismissedToken) || !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if showsResume {
                            if historyStore.isLoading { Text("会話を読み込み中…").foregroundStyle(.secondary) }
                            if isOpeningHistory { Text("会話を再開中…").foregroundStyle(.secondary) }
                            if let error = historyStore.errorMessage {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await historyStore.load(more: historyStore.nextCursor != nil) } }
                            }
                            if let error = resumeError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if candidates.isEmpty && !historyStore.isLoading && historyStore.errorMessage == nil {
                                Text("再開できる会話はありません").foregroundStyle(.secondary)
                            }
                        } else {
                            if skillStore.isLoading { Text("Skillを読み込み中…").foregroundStyle(.secondary) }
                            if let error = skillStore.errorMessage {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await skillStore.load() } }
                            }
                            if candidates.isEmpty && !skillStore.isLoading && skillStore.errorMessage == nil {
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
                                        .disabled(showsResume && (isOpeningHistory || historyStore.isLoading))
                                        .accessibilityValue(index == candidateIndex ? "選択中" : "")
                                        .id(index)
                                    }
                                }
                            }
                            .onChange(of: candidateIndex) { _, index in proxy.scrollTo(index) }
                        }
                        .frame(maxHeight: showsResume ? 480 : 160)
                    }
                    .font(.callout)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    AgentBookTextInput(focus: focus, inputFocus: inputFocus, agentName: agentName, text: text, selection: $selection,
                                       handleKey: handleKey, pasteImages: { images in
                                           store.draft += images.map { .image(AgentImageAttachment(image: $0)) }
                                       })
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
        .padding(.horizontal, 16).padding(.top, 8)
        .task(id: store.isConnected) { if store.isConnected { await skillStore.load() } }
        .task(id: showsSkills) { if showsSkills { await skillStore.load() } }
        .task(id: showsResume) { if showsResume { await historyStore.load() } }
        .onChange(of: token) { _, _ in candidateIndex = 0 }
        .onChange(of: store.draft.agentBookDraftText) { old, new in
            dismissedResume = false
            if new.isEmpty, old.trimmingCharacters(in: .whitespacesAndNewlines) != AgentSlashCommand.skills.rawValue {
                showsSkills = false
            }
        }
    }

    @ViewBuilder
    private func imageAttachments() -> some View {
        let images = store.draft.agentBookImages
        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, attachment in
                        Image(nsImage: attachment.image)
                            .resizable().scaledToFit()
                            .frame(width: 64, height: 64)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("添付画像 \(index + 1)")
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    store.draft.removeAll {
                                        if case .image(let image) = $0 { return image.id == attachment.id }
                                        return false
                                    }
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
            guard !isOpeningHistory, !historyStore.isLoading else { return }
            if let entry = candidate.entry {
                let source = store
                isRequestingResume = true
                Task {
                    defer { isRequestingResume = false }
                    if await resume(entry), source.draft.agentBookDraftText.trimmingCharacters(in: .whitespacesAndNewlines) == AgentSlashCommand.resume.rawValue {
                        source.draft.removeAll { if case .text = $0 { return true }; return false }
                    }
                }
            } else {
                Task { await historyStore.load(more: true) }
            }
            return
        }
        let range = showsSkills ? selection : token?.range ?? selection
        guard range.location >= 0, NSMaxRange(range) <= (text.wrappedValue as NSString).length else { return }
        text.wrappedValue = (text.wrappedValue as NSString).replacingCharacters(in: range, with: candidate.name + " ")
        selection = NSRange(location: range.location + (candidate.name as NSString).length + 1, length: 0)
        if let skill = candidate.skill, !store.draft.contains(where: { if case .skill(let selected) = $0 { return selected.id == skill.id }; return false }) {
            store.draft.append(.skill(skill))
        }
        showsSkills = false
        dismissedToken = nil
    }

    private func submit() {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = AgentSlashCommand(rawValue: value), command != .model else {
            sendInput()
            return
        }
        switch command {
        case .resume:
            if dismissedResume { dismissedResume = false }
            else if !candidates.isEmpty { acceptCandidate(min(candidateIndex, candidates.count - 1)) }
        case .new:
            guard !store.isBusy, !store.isResuming, !store.isChangingModel, !isOpeningHistory else { return }
            text.wrappedValue = ""
            newConversation()
        case .skills:
            text.wrappedValue = ""
            selection = NSRange(location: 0, length: 0)
            showsSkills = true
        case .status:
            guard store.isConnected, !store.isResuming, !store.isLoadingStatus else { return }
            text.wrappedValue = ""
            Task { await store.loadStatus(recordResult: true) }
        case .stop:
            text.wrappedValue = ""
            Task { await store.interrupt(recordResult: true) }
        case .model:
            break
        }
    }

    private func sendInput() {
        guard store.canSend || store.isBusy, !store.isResuming, !store.isChangingModel, !isOpeningHistory,
              !store.isStopping, !store.isSendingAdditionalInput else { return }
        Task {
            let draft = store.draft
            let input = draft.filter { item in
                if case .skill(let skill) = item { return skill.agentBookIsMentioned(in: draft.agentBookDraftText) }
                return true
            }
            if store.isBusy {
                if await store.sendAdditionalInput(input) {
                    if store.draft == draft { store.draft = [] }
                    else {
                        let images = Set(input.agentBookImages.map(\.id))
                        store.draft.removeAll { if case .image(let image) = $0 { return images.contains(image.id) }; return false }
                    }
                }
            } else {
                await store.send(input)
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if [36, 76].contains(event.keyCode), modifiers == .command { submit(); return true }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53 {
            dismissedToken = token
            dismissedResume = true
            showsSkills = false
            candidateIndex = 0
            focus.activateReading()
            return true
        }
        if showsResume && (historyStore.isLoading || isOpeningHistory || candidates.isEmpty) {
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

// The book renders submitted input in one TextKit document, across page boundaries.
extension Array where Element == AgentInput {
    var agentBookDraftText: String {
        compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    var agentBookPrompt: String {
        let text = agentBookDraftText
        return compactMap { input in
            switch input {
            case .text(let text): text
            case .skill(let skill): skill.agentBookIsMentioned(in: text) ? nil : skill.name
            case .image: nil
            case .slashCommand(let command): command.rawValue
            }
        }.joined(separator: "\n")
    }

    var agentBookImages: [AgentImageAttachment] {
        compactMap { if case .image(let image) = $0 { image } else { nil } }
    }
}

private extension AgentHistoryEntry {
    var agentBookTitle: String {
        [name, preview].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? id
    }
}

private extension AgentSkill {
    func agentBookIsMentioned(in text: String) -> Bool {
        let pattern = "(?<!\\S)\\$" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}_-])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension AgentSlashCommand {
    var agentBookDescription: String {
        switch self {
        case .new: "新しい会話"
        case .stop: "作業を停止"
        case .skills: "Skillを選択"
        case .status: "状態を確認"
        case .resume: "過去の会話を再開"
        case .model: ""
        }
    }
}

@MainActor
protocol AgentBookReadingSurface: AnyObject {
    func isReading(in window: NSWindow?) -> Bool
    func activateReading()
    func movePage(_ offset: Int)
    func scrollPage(_ offset: Int)
}

@MainActor
final class AgentBookFocus {
    weak var readingView: (any AgentBookReadingSurface)?
    weak var inputView: NSView?

    func isReading(in window: NSWindow) -> Bool { readingView?.isReading(in: window) == true }
    func activateReading() { readingView?.activateReading() }
    func movePage(_ offset: Int) { readingView?.movePage(offset) }
    func scrollPage(_ offset: Int) { readingView?.scrollPage(offset) }
    func activateInput() {
        guard let inputView, !inputView.isHiddenOrHasHiddenAncestor else { return }
        inputView.window?.makeFirstResponder(inputView)
    }
}

private struct AgentBookTextInput: NSViewRepresentable {
    let focus: AgentBookFocus
    let inputFocus: AgentBookFocus?
    let agentName: String
    @Environment(\.isRetainedPageActive) private var isActive
    @Binding var text: String
    @Binding var selection: NSRange
    let handleKey: (NSEvent) -> Bool
    let pasteImages: ([NSImage]) -> Void

    func makeNSView(context: Context) -> AgentBookInputScrollView {
        let view = AgentBookInputTextView()
        view.bookFocus = focus
        focus.inputView = view
        if isActive { inputFocus?.inputView = view }
        view.delegate = context.coordinator
        view.setAccessibilityLabel(agentName + "に依頼する")
        view.setAccessibilityHelp("⌘Enterで送信。⌘Vで画像も貼り付け。/でコマンド、$でSkillを選択。")
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13, weight: .light)
        view.textColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        let scroll = AgentBookInputScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: AgentBookInputScrollView, context: Context) {
        guard let view = scroll.documentView as? AgentBookInputTextView else { return }
        scroll.needsLayout = true
        focus.inputView = view
        view.setAccessibilityLabel(agentName + "に依頼する")
        let becameActive = isActive && !view.isPageActive
        view.isPageActive = isActive
        if becameActive {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isPageActive, !view.isHiddenOrHasHiddenAncestor else { return }
                view.bookFocus?.activateInput()
            }
        }
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        view.handleKey = handleKey
        view.pasteImages = pasteImages
        if !view.hasMarkedText(), view.string != text {
            let range = NSRange(location: 0, length: (view.string as NSString).length)
            view.insertText(text, replacementRange: range)
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        } else if !view.hasMarkedText(), view.selectedRange() != selection, NSMaxRange(selection) <= (text as NSString).length {
            view.setSelectedRange(selection)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: AgentBookInputScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let view = scroll.documentView as? AgentBookInputTextView,
              let font = view.font, let layout = view.layoutManager else { return nil }
        let maximumHeight = ceil(layout.defaultLineHeight(for: font) * 15)
        return CGSize(width: width, height: min(view.measuredHeight(for: width), maximumHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentBookTextInput
        var isUpdating = false
        init(_ parent: AgentBookTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            parent.selection = view.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            let range = view.selectedRange()
            if parent.selection != range { parent.selection = range }
        }
    }
}

private final class AgentBookInputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let view = documentView as? AgentBookInputTextView else { return }
        let width = max(contentSize.width, 1)
        let size = CGSize(width: width, height: max(contentSize.height, view.measuredHeight(for: width)))
        guard view.frame.size != size else { return }
        view.setFrameSize(size)
        if window?.firstResponder === view {
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

private final class AgentBookInputTextView: NSTextView {
    weak var bookFocus: AgentBookFocus?
    var isPageActive = false
    var handleKey: ((NSEvent) -> Bool)?
    var pasteImages: (([NSImage]) -> Void)?

    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let font else { return 20 }
        // Measure separately: SwiftUI probes widths without resizing the live editor.
        let storage = NSTextStorage(attributedString: attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY,
                        layout.defaultLineHeight(for: font)))
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.png, .tiff] + super.readablePasteboardTypes
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .png || type == .tiff else { return super.readSelection(from: pasteboard, type: type) }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
              !images.isEmpty, let pasteImages else { return false }
        pasteImages(images)
        return true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: max(newSize.width, 1), height: .greatestFiniteMagnitude)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isPageActive, !isHiddenOrHasHiddenAncestor, window != nil { bookFocus?.activateInput() }
    }
}
