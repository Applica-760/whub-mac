import SwiftUI

enum IconList {
    private static let code = "chevron.left.forwardslash.chevron.right"
    private static let symbols: [String: String] = [
        "c": code, "cc": code, "cpp": code, "go": code,
        "h": code, "hpp": code, "java": code, "kt": code,
        "kts": code, "m": code, "mm": code, "py": code,
        "rb": code, "rs": code,
        "css": "paintbrush", "scss": "paintbrush",
        "html": "globe",
        "js": "curlybraces", "json": "curlybraces", "jsx": "curlybraces",
        "toml": "curlybraces", "ts": "curlybraces", "tsx": "curlybraces",
        "yaml": "curlybraces", "yml": "curlybraces",
        "md": "doc.richtext", "pdf": "doc.richtext",
        "sh": "terminal", "zsh": "terminal",
        "sql": "cylinder",
        "swift": "swift",
        "xml": "doc.text",
        "gif": "photo", "heic": "photo", "jpeg": "photo", "jpg": "photo",
        "png": "photo", "svg": "photo",
        "m4a": "music.note", "mp3": "music.note", "wav": "music.note",
        "m4v": "film", "mov": "film", "mp4": "film",
    ]

    static func image(for fileURL: URL) -> Image {
        Image(systemName: symbols[fileURL.pathExtension.lowercased()] ?? "doc")
    }
}
