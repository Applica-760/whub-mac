import AppKit

final class MarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let background = storage.attribute(.markdownInlineCodeBackground, at: charRange.location,
                                                 effectiveRange: nil) as? NSColor,
              background == color else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // Selection and other backgrounds retain AppKit's standard drawing.
        for index in 0..<rectCount {
            NSBezierPath(roundedRect: rectArray[index], xRadius: 4, yRadius: 4).fill()
        }
    }
}
