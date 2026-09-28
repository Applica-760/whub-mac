import Darwin
import Foundation
import WhubCore

enum HostCommandError: LocalizedError {
    case notFound(String)
    case localUnsupported(String)
    case invalidPath

    var errorDescription: String? {
        switch self {
        case let .notFound(name): "Host was not found: \(name)"
        case let .localUnsupported(name): "LocalHost is not supported: \(name)"
        case .invalidPath: "BasePath must be absolute and paths must not contain NUL characters."
        }
    }
}

@MainActor
enum HostCommand {
    static func run(name: String) throws {
        let container = try Container.make()
        guard let host = try HostStore(context: container.mainContext).fetchHosts().first(where: { $0.name == name }) else {
            throw HostCommandError.notFound(name)
        }
        let arguments = try arguments(for: host)
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        guard pointers.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var argv = pointers + [nil]
        _ = argv.withUnsafeMutableBufferPointer { execv("/usr/bin/ssh", $0.baseAddress!) }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func arguments(for host: WhubCore.Host) throws -> [String] {
        guard let host = host as? RemoteHost else {
            throw HostCommandError.localUnsupported(host.name)
        }
        try SSH.validate(hostname: host.hostname, user: host.user, port: host.port)
        guard host.basePath.hasPrefix("/"), !host.basePath.contains("\0"), !host.identityFile.contains("\0") else {
            throw HostCommandError.invalidPath
        }
        var arguments = ["ssh", "-t", "-p", String(host.port)]
        if !host.identityFile.isEmpty { arguments += ["-i", host.identityFile] }
        let path = "'" + host.basePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        arguments += ["-l", host.user, host.hostname, "cd \(path) && exec \"$SHELL\" -l"]
        return arguments
    }
}
