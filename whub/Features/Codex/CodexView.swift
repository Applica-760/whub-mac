import AppKit
import SwiftUI

struct CodexView: View {
    @EnvironmentObject private var store: CodexStore
    @EnvironmentObject private var files: FileViewerStore
    @FocusState private var composerFocused: Bool
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.top, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        if store.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Codex", systemImage: "sparkles").font(.largeTitle.bold())
                                Text("回答を読むための場所。")
                                    .font(.title2)
                                Text("作業履歴は折りたたみ、回答を独立して表示します。\n作業フォルダを選んで、最初のメッセージを送ってください。")
                                    .foregroundStyle(.secondary).lineSpacing(6)
                            }
                            .padding(.vertical, 50)
                        }
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
            composer
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .navigationTitle("Codex")
        .onAppear {
            if store.directory.isEmpty { store.directory = files.gitRootURL?.path ?? NSHomeDirectory() }
            composerFocused = true
        }
        .alert("新しい会話を始めますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("新しい会話") { store.reset(); composerFocused = true }
        } message: {
            Text("この画面の会話をクリアします。MVPでは過去の会話を選び直す機能はありません。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: chooseDirectory) {
                Label(URL(fileURLWithPath: store.directory).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
            .help(store.directory)
            .disabled(!store.canConfigure)
            Picker("権限", selection: $store.writable) {
                Text("読み取りのみ").tag(false)
                Text("編集可").tag(true)
            }
            .fixedSize()
            .disabled(!store.canConfigure)
            Spacer()
            Text(store.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button("新しい会話", systemImage: "square.and.pencil") {
                if store.turns.isEmpty { store.reset() } else { confirmsReset = true }
            }
            .disabled(store.isBusy)
        }
    }

    private var composer: some View {
        WidgetFrame {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Codexに依頼する…", text: $store.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(3...8)
                    .focused($composerFocused)
                HStack {
                    Text(store.requests.isEmpty ? (store.isBusy ? "作業中" : "⌘Enterで送信") : "確認待ち")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.isBusy {
                        Button(store.isStopping ? "停止中…" : "停止", systemImage: "stop.fill") {
                            Task { await store.interrupt() }
                        }
                        .disabled(store.isStopping)
                    }
                    Button("送信", systemImage: "arrow.up") {
                        Task { await store.send() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSend)
                }
            }.padding(16)
        }
        .frame(maxWidth: 868)
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 8)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.directory)
        if panel.runModal() == .OK, let url = panel.url { store.directory = url.path }
    }
}

private struct CodexTurnView: View {
    let turn: CodexTurn
    @State private var showsHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("あなた").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(turn.prompt).font(.system(size: 15)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup(isExpanded: $showsHistory) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(turn.history) { item in
                        DisclosureGroup {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 10) {
                                    if item.type == "commandExecution" { Text(item.title).bold() }
                                    Text(item.text.isEmpty ? "出力なし" : item.text)
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 8)
                            }
                        } label: {
                            Label(item.title, systemImage: item.status == "failed" ? "xmark.circle" : "terminal")
                                .lineLimit(2)
                        }
                    }
                }.padding(.vertical, 10)
            } label: {
                HStack(spacing: 8) {
                    if turn.status == "inProgress" { ProgressView().controlSize(.small) }
                    Text("作業履歴 · \(turn.history.count)件")
                    Spacer()
                    Text(statusLabel).font(.caption)
                }.foregroundStyle(.secondary)
            }

            if !turn.answers.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label("回答", systemImage: "text.bubble.fill")
                            .font(.headline).foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("コピー", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(turn.answers.map(\.text).joined(separator: "\n\n"), forType: .string)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                    ForEach(turn.answers) { item in CodexMarkdown(source: item.text) }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                        .fill(Color.accentColor).frame(width: 4)
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
            } else if turn.status == "inProgress" {
                Text("回答はここに表示されます。")
                    .font(.callout).foregroundStyle(.tertiary).padding(.vertical, 12)
            }
        }
    }

    private var statusLabel: String {
        switch turn.status {
        case "inProgress": "作業中"
        case "completed": "完了"
        case "interrupted": "停止済み"
        default: "エラー"
        }
    }
}

private struct CodexRequestView: View {
    let request: CodexRequest
    let respond: ([String: Any]) -> Void
    @State private var answers: [String: String] = [:]

    private var questions: [[String: Any]] { request.params["questions"] as? [[String: Any]] ?? [] }

    private func decide(allow: Bool) {
        if request.method == "item/permissions/requestApproval" {
            respond(["permissions": allow ? (request.params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": "turn"])
        } else {
            respond(["decision": allow ? "accept" : "decline"])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.method == "item/tool/requestUserInput" ? "回答が必要です" : "承認が必要です", systemImage: "hand.raised.fill")
                .font(.headline)
            if request.method == "item/tool/requestUserInput" {
                ForEach(questions.indices, id: \.self) { index in
                    let question = questions[index]
                    let id = question["id"] as? String ?? "\(index)"
                    Text(question["question"] as? String ?? "")
                    ForEach((question["options"] as? [[String: String]] ?? []).indices, id: \.self) { optionIndex in
                        let option = (question["options"] as? [[String: String]] ?? [])[optionIndex]
                        Button {
                            answers[id] = option["label"] ?? ""
                        } label: {
                            VStack(alignment: .leading) {
                                Text(option["label"] ?? "")
                                Text(option["description"] ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    let binding = Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
                    if question["isSecret"] as? Bool == true {
                        SecureField("回答", text: binding)
                    } else {
                        TextField("回答を入力", text: binding)
                    }
                }
                Button("回答を送信") {
                    respond(["answers": answers.mapValues { ["answers": [$0]] }])
                }
                .disabled(questions.contains { (answers[$0["id"] as? String ?? ""] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            } else {
                if let reason = request.params["reason"] as? String { Text(reason) }
                if let command = request.params["command"] as? String {
                    Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if let cwd = request.params["cwd"] as? String { Text(cwd).font(.caption).foregroundStyle(.secondary) }
                if let preview = request.params["changePreview"] as? String {
                    ScrollView {
                        Text(preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxHeight: 120)
                }
                if let permissions = request.params["permissions"] as? [String: Any] {
                    Text(CodexStore.pretty(permissions)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                DisclosureGroup("要求の詳細") {
                    Text(CodexStore.pretty(request.params)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button("拒否", role: .destructive) { decide(allow: false) }
                    Button("今回だけ許可") { decide(allow: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
