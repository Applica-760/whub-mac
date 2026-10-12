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
    @EnvironmentObject private var tabsStore: CodexTabsStore
    let focus: CodexBookFocus
    let newConversation: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var candidateIndex = 0
    @State private var dismissedToken: CodexInputToken?
    @State private var showsSkills = false
    @State private var dismissedResume = false

    private var token: CodexInputToken? { CodexInputToken.at(selection, in: store.draft) }
    static func isResumeInput(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == CodexCommand.resume.rawValue
    }

    private var showsResume: Bool { Self.isResumeInput(store.draft) && !dismissedResume }
    private var candidates: [(name: String, detail: String, skill: CodexSkill?, thread: CodexRecentThread?)] {
        if showsResume {
            var entries = store.recentThreads.map {
                (name: $0.title, detail: $0.directory + " · " + $0.updatedAt.formatted(date: .abbreviated, time: .shortened),
                 skill: Optional<CodexSkill>.none, thread: Optional($0))
            }
            if store.nextThreadCursor != nil { entries.append(("さらに読み込む", "", nil, nil)) }
            return entries
        }
        if showsSkills {
            return store.skills.map { ("$" + $0.name, $0.description, $0, nil) }
        }
        guard let token, token != dismissedToken else { return [] }
        if token.text.hasPrefix("/") {
            return CodexCommand.allCases.filter { $0.rawValue.hasPrefix(token.text.lowercased()) }.map { ($0.rawValue, $0.description, nil, nil) }
        }
        return store.skills.filter { ("$" + $0.name).lowercased().hasPrefix(token.text.lowercased()) }
            .map { ("$" + $0.name, $0.description, $0, nil) }
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                imageAttachments()
                if showsResume || showsSkills || (token?.text.hasPrefix("$") == true && token != dismissedToken) || !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if showsResume {
                            if store.isLoadingThreads { Text("会話を読み込み中…").foregroundStyle(.secondary) }
                            if tabsStore.isResuming { Text("会話を再開中…").foregroundStyle(.secondary) }
                            if let error = store.threadListError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await store.loadRecentThreads(more: store.nextThreadCursor != nil) } }
                            }
                            if let error = tabsStore.resumeError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if candidates.isEmpty && !store.isLoadingThreads && store.threadListError == nil {
                                Text("再開できる会話はありません").foregroundStyle(.secondary)
                            }
                        } else {
                            if store.isLoadingSkills { Text("Skillを読み込み中…").foregroundStyle(.secondary) }
                            if let error = store.skillError {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                                Button("再読み込み") { Task { await store.loadSkills(forceReload: true) } }
                            }
                            if candidates.isEmpty && !store.isLoadingSkills && store.skillError == nil {
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
                                        .disabled(showsResume && (tabsStore.isResuming || store.isLoadingThreads))
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
        .task(id: store.directory) { await store.loadSkills() }
        .onChange(of: token) { _, _ in candidateIndex = 0 }
        .onChange(of: store.directory) { _, _ in store.selectedSkills = [] }
        .onChange(of: store.draft) { _, text in
            dismissedResume = false
            if text.isEmpty { showsSkills = false }
        }
        .task(id: showsResume) {
            if showsResume { await store.loadRecentThreads() }
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
            guard !tabsStore.isResuming, !store.isLoadingThreads else { return }
            if let thread = candidate.thread {
                let source = store
                Task {
                    if await tabsStore.resume(thread), Self.isResumeInput(source.draft) {
                        source.draft = ""
                    }
                }
            } else {
                Task { await store.loadRecentThreads(more: true) }
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

    private func submit() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = CodexCommand(rawValue: text) else {
            guard store.canSend else { return }
            let skills = store.selectedSkills.filter { $0.isMentioned(in: store.draft) }
            Task { await store.send(skills: skills) }
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
            guard !store.isBusy else { return }
            store.draft = ""
            newConversation()
            return
        }
        store.draft = ""
        if command == .skills {
            selection = NSRange(location: 0, length: 0)
            showsSkills = true
        }
        Task { await store.runCommand(command) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if [36, 76].contains(event.keyCode), modifiers == .command { submit(); return true }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53, showsResume || showsSkills || token != nil {
            dismissedToken = token
            dismissedResume = true
            showsSkills = false
            return true
        }
        if showsResume && (store.isLoadingThreads || tabsStore.isResuming || candidates.isEmpty) {
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

private struct CodexTextInput: NSViewRepresentable {
    let focus: CodexBookFocus
    @Environment(\.isRetainedPageActive) private var isActive
    @Binding var text: String
    @Binding var selection: NSRange
    let handleKey: (NSEvent) -> Bool
    let pasteImages: ([NSImage]) -> Void

    func makeNSView(context: Context) -> CodexTextView {
        let view = CodexTextView()
        view.bookFocus = focus
        focus.inputView = view
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Codexに依頼する")
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
        return view
    }

    func updateNSView(_ view: CodexTextView, context: Context) {
        focus.inputView = view
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CodexTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let font = view.font else { return nil }
        // SwiftUI probes multiple widths; measurement must not change the live text container.
        let storage = NSTextStorage(attributedString: view.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY, layout.defaultLineHeight(for: font))
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexTextInput
        var isUpdating = false
        init(_ parent: CodexTextInput) { self.parent = parent }
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

final class CodexTextView: NSTextView {
    weak var bookFocus: CodexBookFocus?
    var isPageActive = false
    var handleKey: ((NSEvent) -> Bool)?
    var pasteImages: (([NSImage]) -> Void)?

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
