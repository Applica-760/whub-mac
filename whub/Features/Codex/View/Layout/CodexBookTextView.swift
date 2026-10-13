import AppKit
import SwiftUI

/// Two-page rendering surface; conversation integration and pagination follow in stage two.
struct CodexBookTextView: NSViewRepresentable {
    var markdown = Self.sample
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> CodexBookTextSurface { CodexBookTextSurface() }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodexBookTextSurface, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func updateNSView(_ view: CodexBookTextSurface, context: Context) {
        view.update(markdown: markdown, colorScheme: colorScheme)
    }

    private static let sample = """
    # AppKit 見開き試作
    この段落から表や数式をまたいで範囲選択できます。**太字**・*斜体*・`インラインコード`も描画します。

    | 項目 | 内容 |
    | --- | --- |
    | 本文 | 段落をまたぐコピー |
    | 数式 | コピー時に元の式へ復元 |

    数式：$E = mc^2$

    > 引用もMarkdownから描画しています。

    1. コードは横スクロールできます。
    2. 長い行を含めて複数行を選択し、コピーしてください。

    ```swift
    let message = "この行は横スクロール確認用です。折り返さず、見えていない部分も元のコードのままコピーできることを確認します。"
    print(message)
    ```
    """
}

final class CodexBookTextSurface: NSView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private var pages: [CodexBookNativeTextView] = []
    private var markdown = ""
    private var colorScheme: ColorScheme = .light
    private var document: CodexMarkdownDocument?
    private var documentWidth: CGFloat = 0
    private var needsDocument = true
    private var codeViews: [NSHostingView<CodexBookCodeBlock>] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        storage.addLayoutManager(manager)
        for _ in 0..<2 {
            let container = NSTextContainer(containerSize: .zero)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            let page = CodexBookNativeTextView(frame: .zero, textContainer: container)
            page.isEditable = false
            page.isSelectable = true
            page.isRichText = true
            page.isVerticallyResizable = false
            page.isHorizontallyResizable = false
            page.textContainerInset = NSSize(width: 28, height: 28)
            page.drawsBackground = false
            page.autoresizingMask = []
            addSubview(page)
            pages.append(page)
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(markdown: String, colorScheme: ColorScheme) {
        guard self.markdown != markdown || self.colorScheme != colorScheme else { return }
        self.markdown = markdown
        self.colorScheme = colorScheme
        needsDocument = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(1, (bounds.width - 32) / 2)
        let contentWidth = max(1, width - 56)
        for (index, page) in pages.enumerated() {
            page.frame = NSRect(x: CGFloat(index) * (width + 32), y: 0,
                                width: width, height: bounds.height)
            page.textContainer?.containerSize = NSSize(width: contentWidth, height: max(1, bounds.height - 56))
        }
        if needsDocument || documentWidth != contentWidth {
            let selected = pages[0].selectedRange()
            let rendered = CodexMarkdownDocument(source: markdown, width: contentWidth, colorScheme: colorScheme)
            storage.setAttributedString(rendered.text)
            let start = min(selected.location, storage.length)
            pages[0].setSelectedRange(NSRange(location: start, length: min(selected.length, storage.length - start)))
            document = rendered
            documentWidth = contentWidth
            needsDocument = false
            codeViews.forEach { $0.removeFromSuperview() }
            codeViews = rendered.codes.map { code in
                NSHostingView(rootView: CodexBookCodeBlock(code: code.text))
            }
        }
        guard let document else { return }
        for (index, code) in document.codes.enumerated() {
            let scroll = codeViews[index]
            scroll.isHidden = true
            let glyphs = manager.glyphRange(forCharacterRange: code.range, actualCharacterRange: nil)
            for page in pages {
                guard let container = page.textContainer else { continue }
                manager.ensureLayout(for: container)
                let range = manager.glyphRange(for: container)
                guard NSLocationInRange(glyphs.location, range) else { continue }
                if scroll.superview !== page { page.addSubview(scroll) }
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                scroll.frame = NSRect(x: rect.minX + page.textContainerOrigin.x,
                                      y: rect.minY + page.textContainerOrigin.y,
                                      width: code.size.width, height: code.size.height)
                scroll.isHidden = false
                break
            }
        }
    }
}

private final class CodexBookNativeTextView: NSTextView {
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        var text = ""
        for value in selectedRanges {
            storage.enumerateAttributes(in: value.rangeValue) { attributes, range, _ in
                text += attributes[.codexFormulaSource] as? String
                    ?? attributes[.codexBookCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(text, forType: .string)
    }
}

// Keep the existing code-block chrome; AppKit owns text selection and horizontal scrolling.
private struct CodexBookCodeBlock: View {
    let code: String

    var body: some View {
        CodexBookCodeScroll(code: code)
            .padding(.trailing, 36)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button("コードをコピー", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .help("コードをコピー")
                .padding(12)
            }
    }
}

private struct CodexBookCodeScroll: NSViewRepresentable {
    let code: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = NSTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != code { text.string = code }
        guard let layout = text.layoutManager, let container = text.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        text.frame.size = NSSize(width: ceil(used.width) + 24, height: ceil(used.height) + 24)
        assert(text.string == code, "Horizontal scrolling must not insert line breaks into the source")
    }
}
