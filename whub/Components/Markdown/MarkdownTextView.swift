import AppKit
import SwiftUI

final class MarkdownTextView: NSTextView {
    override func accessibilityChildren() -> [Any]? {
        // NSTextView exposes attachment cells but omits the views overlaid on them.
        (super.accessibilityChildren() ?? []) + subviews.filter { $0 is NSHostingView<MarkdownCodeBlock> }
    }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        var result = ""
        for selection in selectedRanges {
            storage.enumerateAttributes(in: selection.rangeValue) { attributes, range, _ in
                result += attributes[.markdownFormulaSource] as? String
                    ?? attributes[.markdownCodeSource] as? String
                    ?? (storage.string as NSString).substring(with: range)
            }
        }
        return pasteboard.setString(result, forType: .string)
    }
}
