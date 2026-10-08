import Foundation
import SwiftData

enum FileLocation: Hashable {
    case local(URL)
    case remote(hostID: PersistentIdentifier, path: String)

    var localURL: URL? {
        guard case let .local(url) = self else { return nil }
        return url
    }
}
