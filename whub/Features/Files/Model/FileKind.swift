import Foundation

nonisolated struct FileKind: Equatable, Sendable {
    let iconName: String
    let highlightLanguage: String?
    var isMarkdown: Bool { self == Self.kinds["md"] }

    static func resolve(path: String) -> FileKind {
        kinds[(path as NSString).pathExtension.lowercased()] ?? unknown
    }

    private static let codeIcon = "chevron.left.forwardslash.chevron.right"
    private static let unknown = FileKind(iconName: "doc", highlightLanguage: nil)
    private static let kinds: [String: FileKind] = [
        "c": .init(iconName: codeIcon, highlightLanguage: "c"),
        "cc": .init(iconName: codeIcon, highlightLanguage: "cpp"),
        "cpp": .init(iconName: codeIcon, highlightLanguage: "cpp"),
        "go": .init(iconName: codeIcon, highlightLanguage: "go"),
        "h": .init(iconName: codeIcon, highlightLanguage: "c"),
        "hpp": .init(iconName: codeIcon, highlightLanguage: "cpp"),
        "java": .init(iconName: codeIcon, highlightLanguage: "java"),
        "kt": .init(iconName: codeIcon, highlightLanguage: "kotlin"),
        "kts": .init(iconName: codeIcon, highlightLanguage: "kotlin"),
        "m": .init(iconName: codeIcon, highlightLanguage: "objectivec"),
        "mm": .init(iconName: codeIcon, highlightLanguage: "objectivec"),
        "py": .init(iconName: codeIcon, highlightLanguage: "python"),
        "rb": .init(iconName: codeIcon, highlightLanguage: "ruby"),
        "rs": .init(iconName: codeIcon, highlightLanguage: "rust"),
        "css": .init(iconName: "paintbrush", highlightLanguage: "css"),
        "scss": .init(iconName: "paintbrush", highlightLanguage: "scss"),
        "html": .init(iconName: "globe", highlightLanguage: "xml"),
        "js": .init(iconName: "curlybraces", highlightLanguage: "javascript"),
        "json": .init(iconName: "curlybraces", highlightLanguage: "json"),
        "jsx": .init(iconName: "curlybraces", highlightLanguage: "javascript"),
        "toml": .init(iconName: "curlybraces", highlightLanguage: "ini"),
        "ts": .init(iconName: "curlybraces", highlightLanguage: "typescript"),
        "tsx": .init(iconName: "curlybraces", highlightLanguage: "typescript"),
        "yaml": .init(iconName: "curlybraces", highlightLanguage: "yaml"),
        "yml": .init(iconName: "curlybraces", highlightLanguage: "yaml"),
        "md": .init(iconName: "doc.richtext", highlightLanguage: "markdown"),
        "pdf": .init(iconName: "doc.richtext", highlightLanguage: nil),
        "sh": .init(iconName: "terminal", highlightLanguage: "bash"),
        "zsh": .init(iconName: "terminal", highlightLanguage: "bash"),
        "sql": .init(iconName: "cylinder", highlightLanguage: "sql"),
        "swift": .init(iconName: "swift", highlightLanguage: "swift"),
        "xml": .init(iconName: "doc.text", highlightLanguage: "xml"),
        "gif": .init(iconName: "photo", highlightLanguage: nil),
        "heic": .init(iconName: "photo", highlightLanguage: nil),
        "jpeg": .init(iconName: "photo", highlightLanguage: nil),
        "jpg": .init(iconName: "photo", highlightLanguage: nil),
        "png": .init(iconName: "photo", highlightLanguage: nil),
        "svg": .init(iconName: "photo", highlightLanguage: nil),
        "m4a": .init(iconName: "music.note", highlightLanguage: nil),
        "mp3": .init(iconName: "music.note", highlightLanguage: nil),
        "wav": .init(iconName: "music.note", highlightLanguage: nil),
        "m4v": .init(iconName: "film", highlightLanguage: nil),
        "mov": .init(iconName: "film", highlightLanguage: nil),
        "mp4": .init(iconName: "film", highlightLanguage: nil),
    ]
}
