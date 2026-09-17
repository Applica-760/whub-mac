import Foundation

enum FileKind {
    case code(language: String, systemImage: String)
    case preview(systemImage: String)

    var systemImage: String {
        switch self {
        case let .code(_, systemImage), let .preview(systemImage): systemImage
        }
    }

    var language: String? {
        guard case let .code(language, _) = self else { return nil }
        return language
    }
}

private let codeImage = "chevron.left.forwardslash.chevron.right"
private let fileKinds: [String: FileKind] = [
    "c": .code(language: "c", systemImage: codeImage),
    "cc": .code(language: "cpp", systemImage: codeImage),
    "cpp": .code(language: "cpp", systemImage: codeImage),
    "css": .code(language: "css", systemImage: "paintbrush"),
    "go": .code(language: "go", systemImage: codeImage),
    "h": .code(language: "c", systemImage: codeImage),
    "hpp": .code(language: "cpp", systemImage: codeImage),
    "html": .code(language: "xml", systemImage: "globe"),
    "java": .code(language: "java", systemImage: codeImage),
    "js": .code(language: "javascript", systemImage: "curlybraces"),
    "json": .code(language: "json", systemImage: "curlybraces"),
    "jsx": .code(language: "javascript", systemImage: "curlybraces"),
    "kt": .code(language: "kotlin", systemImage: codeImage),
    "kts": .code(language: "kotlin", systemImage: codeImage),
    "m": .code(language: "objectivec", systemImage: codeImage),
    "md": .code(language: "markdown", systemImage: "doc.richtext"),
    "mm": .code(language: "objectivec", systemImage: codeImage),
    "py": .code(language: "python", systemImage: codeImage),
    "rb": .code(language: "ruby", systemImage: codeImage),
    "rs": .code(language: "rust", systemImage: codeImage),
    "scss": .code(language: "scss", systemImage: "paintbrush"),
    "sh": .code(language: "bash", systemImage: "terminal"),
    "sql": .code(language: "sql", systemImage: "cylinder"),
    "swift": .code(language: "swift", systemImage: "swift"),
    "toml": .code(language: "ini", systemImage: "curlybraces"),
    "ts": .code(language: "typescript", systemImage: "curlybraces"),
    "tsx": .code(language: "typescript", systemImage: "curlybraces"),
    "xml": .code(language: "xml", systemImage: "doc.text"),
    "yaml": .code(language: "yaml", systemImage: "curlybraces"),
    "yml": .code(language: "yaml", systemImage: "curlybraces"),
    "zsh": .code(language: "bash", systemImage: "terminal"),
    "gif": .preview(systemImage: "photo"),
    "heic": .preview(systemImage: "photo"),
    "jpeg": .preview(systemImage: "photo"),
    "jpg": .preview(systemImage: "photo"),
    "m4a": .preview(systemImage: "music.note"),
    "m4v": .preview(systemImage: "film"),
    "mov": .preview(systemImage: "film"),
    "mp3": .preview(systemImage: "music.note"),
    "mp4": .preview(systemImage: "film"),
    "pdf": .preview(systemImage: "doc.richtext"),
    "png": .preview(systemImage: "photo"),
    "svg": .preview(systemImage: "photo"),
    "wav": .preview(systemImage: "music.note"),
]

func fileKind(for fileURL: URL) -> FileKind {
    fileKinds[fileURL.pathExtension.lowercased()] ?? .preview(systemImage: "doc")
}
