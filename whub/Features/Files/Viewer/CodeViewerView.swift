import AppKit
import Highlighter
import SwiftUI

@MainActor private let codeHighlighter = Highlighter()

struct CodeViewerView: NSViewRepresentable {
    let fileURL: URL
    let language: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            fatalError("Expected NSTextView")
        }
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let source = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "Unable to display this file"
        let dark = textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        codeHighlighter?.setTheme(
            dark ? "xcode-dusk" : "xcode",
            withFont: "Menlo-Regular",
            ofSize: 13
        )
        textView.textStorage?.setAttributedString(
            codeHighlighter?.highlight(source, as: language)
                ?? NSAttributedString(
                    string: source,
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
        )
    }
}
