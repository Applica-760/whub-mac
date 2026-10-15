import Foundation
import Hummingbird

enum ConfigurationError: Error, CustomStringConvertible {
    case invalidAddress, invalidPort, missingRoot

    var description: String {
        switch self {
        case .invalidAddress: "WHUB_SERVER_HOST must not be empty."
        case .invalidPort: "WHUB_SERVER_PORT must be an integer between 1 and 65535."
        case .missingRoot: "WHUB_SERVER_ROOT must specify an accessible absolute directory without symlinks."
        }
    }
}

@main
struct WhubServer {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WHUB_SERVER_HOST"] ?? "127.0.0.1"
        guard !host.isEmpty else { throw ConfigurationError.invalidAddress }
        guard let port = Int(environment["WHUB_SERVER_PORT"] ?? "8080"), (1...65535).contains(port) else {
            throw ConfigurationError.invalidPort
        }

        guard let root = environment["WHUB_SERVER_ROOT"] else { throw ConfigurationError.missingRoot }
        let files = try FilesService(root: root)
        let router = makeRouter(files: FilesAPI(service: files))

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }
}
