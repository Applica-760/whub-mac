import Foundation

enum SSHError: LocalizedError {
    case emptyCommand
    case invalidHostname
    case invalidUser
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "SSH command is required."
        case .invalidHostname: "SSH hostname is invalid."
        case .invalidUser: "SSH user is invalid."
        case .invalidPort: "SSH port must be between 1 and 65535."
        }
    }
}

@MainActor
enum SSH {
    static func validate(hostname: String, user: String, port: Int) throws {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !hostname.isEmpty, !hostname.hasPrefix("-"), !hostname.contains("@"),
              hostname.rangeOfCharacter(from: forbidden) == nil else {
            throw SSHError.invalidHostname
        }
        guard !user.isEmpty, !user.hasPrefix("-"), !user.contains("@"),
              user.rangeOfCharacter(from: forbidden) == nil else {
            throw SSHError.invalidUser
        }
        guard (1...65535).contains(port) else { throw SSHError.invalidPort }
    }

    static func run(_ command: [String], on host: RemoteHost) async throws -> Int32 {
        guard !command.isEmpty else { throw SSHError.emptyCommand }
        try validate(hostname: host.hostname, user: host.user, port: host.port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-p", String(host.port)]
        if !host.identityFile.isEmpty {
            arguments += ["-i", host.identityFile]
        }
        arguments += ["\(host.user)@\(host.hostname)", command.map(quote).joined(separator: " ")]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
