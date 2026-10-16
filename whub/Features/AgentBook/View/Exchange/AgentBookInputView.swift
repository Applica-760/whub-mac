import AppKit
import SwiftUI

struct AgentBookInputView<Candidates: View>: View {
    @Binding var input: [AgentInput]
    let focus: CodexBookFocus
    let isBusy: Bool
    let isStopping: Bool
    let send: () -> Void
    let interrupt: () -> Void
    let handleCandidateKey: (NSEvent, Binding<NSRange>) -> Bool
    @ViewBuilder let candidates: (Binding<NSRange>) -> Candidates
    @State private var selection = NSRange(location: 0, length: 0)

    private var text: Binding<String> {
        Binding(
            get: { input.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n") },
            set: { text in
                // Editing the single existing text surface keeps every non-text input intact.
                let insertion = input.firstIndex { if case .text = $0 { return true }; return false } ?? 0
                input.removeAll { if case .text = $0 { return true }; return false }
                input.insert(.text(text), at: min(insertion, input.count))
            }
        )
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                imageAttachments()
                candidates($selection)
                HStack(alignment: .bottom, spacing: 12) {
                    CodexTextInput(focus: focus, text: text, selection: $selection, handleKey: handleKey,
                                       pasteImages: { images in input += images.map { .image(AgentImageAttachment(image: $0)) } })
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                        .accessibilityAction(named: Text("送信")) { send() }
                    ZStack {
                        Color.clear
                        if isBusy {
                            Button(isStopping ? "停止中…" : "停止", systemImage: "stop.fill", action: interrupt)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .frame(width: 24, height: 24)
                                .background(.quaternary, in: Circle())
                                .contentShape(Circle())
                                .help(isStopping ? "停止中…" : "停止")
                                .disabled(isStopping)
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
    }

    @ViewBuilder
    private func imageAttachments() -> some View {
        let images = input.agentBookImages
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
                                    input.removeAll {
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

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if [36, 76].contains(event.keyCode), modifiers == .command { send(); return true }
        if handleCandidateKey(event, $selection) { return true }
        if event.keyCode == 53, modifiers.isEmpty { focus.activateReading(); return true }
        return false
    }
}

// The book renders submitted input in one TextKit document, across page boundaries.
extension Array where Element == AgentInput {
    var agentBookPrompt: String {
        compactMap { input in
            switch input {
            case .text(let text): text
            case .skill(let skill): skill.name
            case .image: nil
            case .slashCommand(let command): command.rawValue
            }
        }.joined(separator: "\n")
    }

    var agentBookImages: [AgentImageAttachment] {
        compactMap { if case .image(let image) = $0 { image } else { nil } }
    }
}
