import AppKit
import SwiftMath
import SwiftUI

struct MarkdownInlineRenderer {
    var fontSize: CGFloat = 15
    var weight: NSFont.Weight = .light
    var colorScheme: ColorScheme = .light

    func attributed(_ source: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in source.runs {
            if let formula = run[MarkdownFormulaAttribute.self], let rendered = render(formula, size: formula.display ? 22 : fontSize) {
                let attachment = NSTextAttachment()
                attachment.image = rendered.image
                attachment.bounds = CGRect(x: 0, y: -rendered.descent, width: rendered.image.size.width, height: rendered.image.size.height)
                let part = NSMutableAttributedString(attachment: attachment)
                part.addAttribute(.markdownFormulaSource, value: formula.source, range: NSRange(location: 0, length: part.length))
                result.append(part)
                continue
            }
            let intent = run.inlinePresentationIntent ?? []
            let runWeight: NSFont.Weight = intent.contains(.stronglyEmphasized) ? .bold : weight
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: 14, weight: runWeight)
                : NSFont.systemFont(ofSize: fontSize, weight: runWeight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) {
                let background = NSColor.secondaryLabelColor.withAlphaComponent(0.16)
                attributes[.backgroundColor] = background
                attributes[.markdownInlineCodeBackground] = background
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes))
        }
        return result
    }

    private final class Rendered: NSObject {
        let image: NSImage
        let descent: CGFloat
        init(image: NSImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }

    private static let cache: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.countLimit = 128
        return cache
    }()

    private func render(_ formula: MarkdownFormula, size: CGFloat) -> Rendered? {
        guard let latex = formula.latex, !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = "\(size):\(colorScheme):\(formula.display):\(latex)" as NSString
        if let cached = Self.cache.object(forKey: key) { return cached }
        var textColor = NSColor.labelColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            textColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        var math = MathImage(latex: latex, fontSize: size,
                             textColor: textColor,
                             labelMode: formula.display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout, image.size.width > 0, image.size.height > 0 else { return nil }
        let rendered = Rendered(image: image, descent: layout.descent)
        Self.cache.setObject(rendered, forKey: key)
        return rendered
    }
}

extension NSAttributedString.Key {
    static let markdownFormulaSource = NSAttributedString.Key("whub.formulaSource")
    static let markdownInlineCodeBackground = NSAttributedString.Key("whub.inlineCodeBackground")
}

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
