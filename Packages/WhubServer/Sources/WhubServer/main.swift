import Foundation
import Hummingbird

enum ConfigurationError: Error, CustomStringConvertible {
    case invalidAddress, invalidPort

    var description: String {
        switch self {
        case .invalidAddress: "WHUB_SERVER_HOST must not be empty."
        case .invalidPort: "WHUB_SERVER_PORT must be an integer between 1 and 65535."
        }
    }
}

let environment = ProcessInfo.processInfo.environment
let host = environment["WHUB_SERVER_HOST"] ?? "127.0.0.1"
guard !host.isEmpty else { throw ConfigurationError.invalidAddress }
guard let port = Int(environment["WHUB_SERVER_PORT"] ?? "8080"), (1...65535).contains(port) else {
    throw ConfigurationError.invalidPort
}

let router = Router()
router.get("ping") { _, _ -> String in "pong" }

let app = Application(
    router: router,
    configuration: .init(address: .hostname(host, port: port))
)
try await app.runService()
