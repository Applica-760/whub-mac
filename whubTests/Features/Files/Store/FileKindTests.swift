import Foundation
import Testing
@testable import whub

@Suite @MainActor
struct FileKindTests {
    @Test func markdownUsesTheSameDefinitionRegardlessOfCase() {
        let location = FileLocation.local(URL(fileURLWithPath: "/project/README.MD"))
        let kind = location.kind
        #expect(kind == FileKind.resolve(path: "/project/readme.md"))
        #expect(kind.iconName == "doc.richtext")
        #expect(kind.highlightLanguage == "markdown")
        #expect(kind.isMarkdown)
    }

    @Test func aliasesAndIndependentAttributesArePreserved() {
        #expect(FileKind.resolve(path: "file.js") == FileKind.resolve(path: "file.jsx"))
        #expect(FileKind.resolve(path: "file.yaml") == FileKind.resolve(path: "file.yml"))
        let pdf = FileKind.resolve(path: "file.pdf")
        #expect(pdf.iconName == FileKind.resolve(path: "file.md").iconName)
        #expect(pdf.highlightLanguage == nil)
        #expect(!pdf.isMarkdown)
        let html = FileKind.resolve(path: "file.html")
        #expect(html.iconName == "globe")
        #expect(html.highlightLanguage == "xml")
    }

    @Test func unknownOrMissingExtensionUsesDefaultAttributes() {
        for path in ["/project/file.unknown", "/project/README", "/project.md/README", "/project/.md"] {
            let kind = FileKind.resolve(path: path)
            #expect(kind.iconName == "doc")
            #expect(kind.highlightLanguage == nil)
            #expect(!kind.isMarkdown)
        }
    }
}
