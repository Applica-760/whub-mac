import Foundation
import SwiftData

nonisolated enum FileLocation: Hashable, Sendable {
    case local(URL)
    case remote(hostID: PersistentIdentifier, path: String)

    var path: String {
        switch self {
        case let .local(url): url.path
        case let .remote(_, path): path
        }
    }

    var name: String { (path as NSString).lastPathComponent }

    func appending(_ name: String) -> FileLocation {
        switch self {
        case let .local(url): .local(url.appendingPathComponent(name))
        case let .remote(hostID, path):
            .remote(hostID: hostID, path: (path as NSString).appendingPathComponent(name))
        }
    }

    var localURL: URL? {
        guard case let .local(url) = self else { return nil }
        return url
    }
}
