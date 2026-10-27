import Foundation

nonisolated enum EditorTab: Hashable, Sendable {
    case file(FileLocation)
    case diff(FileLocation)
}
