import Foundation

final class ExplorerItem: NSObject {
    let location: FileLocation
    let isDirectory: Bool
    var children: [ExplorerItem]?

    init(location: FileLocation, isDirectory: Bool) {
        self.location = location
        self.isDirectory = isDirectory
    }
}
