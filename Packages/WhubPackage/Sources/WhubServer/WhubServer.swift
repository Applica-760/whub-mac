import Foundation
import Hummingbird
import WhubAgent

enum ConfigurationError: Error, CustomStringConvertible {
    case invalidAddress, invalidPort

    var description: String {
        switch self {
        case .invalidAddress: "WHUB_SERVER_HOST must be 127.0.0.1 or ::1. Connect through SSH forwarding."
        case .invalidPort: "WHUB_SERVER_PORT must be an integer between 1 and 65535."
        }
    }
}

@main
struct WhubServer {
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            guard arguments.count == 3, arguments[0] == "update", arguments[1].hasPrefix("/") else {
                throw ReleaseError("invalid_arguments", "Usage: whub-server [update <absolute-manager-root> <update-id>]")
            }
            let update = try await ServerManager(root: URL(fileURLWithPath: arguments[1])).perform(id: arguments[2])
            guard update.status == "succeeded" else {
                throw ReleaseError(update.errorCode ?? update.status, update.error ?? "Update failed.")
            }
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let host = environment["WHUB_SERVER_HOST"] ?? "127.0.0.1"
        guard ["127.0.0.1", "::1"].contains(host) else { throw ConfigurationError.invalidAddress }
        guard let port = Int(environment["WHUB_SERVER_PORT"] ?? "8080"), (1...65535).contains(port) else {
            throw ConfigurationError.invalidPort
        }

        let runtime = AgentRuntime()
        defer { runtime.shutdown() }
        let router = makeRouter(files: FilesAPI(), manager: try managerAPI(environment), agent: AgentAPI(runtime: runtime),
                                git: GitAPI())

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }

    static func managerAPI(_ values: [String: String]) throws -> ManagerAPI {
        let keys = ["WHUB_SERVER_ENVIRONMENT", "WHUB_MANAGER_ROOT", "WHUB_MANAGER_SOURCE", "WHUB_MANAGER_SWIFT",
                    "WHUB_MANAGER_SERVICE", "WHUB_MANAGER_HEALTH_URL"]
        guard keys.allSatisfy({ values[$0]?.isEmpty == false }),
              let environment = ServerEnvironment(rawValue: values["WHUB_SERVER_ENVIRONMENT"]!),
              ["WHUB_MANAGER_ROOT", "WHUB_MANAGER_SOURCE", "WHUB_MANAGER_SWIFT"].allSatisfy({ values[$0]!.hasPrefix("/") }),
              let healthURL = URL(string: values["WHUB_MANAGER_HEALTH_URL"]!),
              ["http", "https"].contains(healthURL.scheme), healthURL.host != nil,
              let service = values["WHUB_MANAGER_SERVICE"], !service.hasPrefix("-"),
              service.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.@".contains($0)) }) else {
            throw ReleaseError("invalid_configuration", "Manager requires all WHUB_MANAGER_* settings, dev/prod environment and absolute paths.")
        }
        let configuration = ManagerConfiguration(environment: environment,
                                                 source: URL(fileURLWithPath: values["WHUB_MANAGER_SOURCE"]!),
                                                 swift: values["WHUB_MANAGER_SWIFT"]!, service: service,
                                                 healthURL: healthURL)
        let executable: URL
        #if os(Linux)
        executable = URL(fileURLWithPath: "/proc/self/exe")
        #else
        executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        #endif
        let metadata = executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("build.json")
        let running = try? JSONDecoder().decode(BuildArtifact.self, from: Data(contentsOf: metadata))
        return ManagerAPI(manager: ServerManager(root: URL(fileURLWithPath: values["WHUB_MANAGER_ROOT"]!)),
                          configuration: configuration, executable: executable, running: running)
    }
}
