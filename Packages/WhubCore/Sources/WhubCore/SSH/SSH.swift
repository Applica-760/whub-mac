import Foundation
import Darwin

enum SSHError: LocalizedError {
    case emptyCommand, invalidHostname, invalidUser, invalidPort, invalidIdentityFile

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "SSH command is required."
        case .invalidHostname: "SSH hostname is invalid."
        case .invalidUser: "SSH user is invalid."
        case .invalidPort: "SSH port must be between 1 and 65535."
        case .invalidIdentityFile: "SSH identity path contains a NUL character."
        }
    }
}

@MainActor
public enum SSH {
    public static func validate(hostname: String, user: String, port: Int) throws {
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

    static func arguments(_ command: [String], on host: RemoteHost) throws -> [String] {
        guard !command.isEmpty else { throw SSHError.emptyCommand }
        try validate(hostname: host.hostname, user: host.user, port: host.port)
        guard !host.identityFile.contains("\0") else { throw SSHError.invalidIdentityFile }
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                         "-p", String(host.port)]
        if !host.identityFile.isEmpty { arguments += ["-i", host.identityFile] }
        arguments += ["\(host.user)@\(host.hostname)", command.map(quote).joined(separator: " ")]
        return arguments
    }

    static func start(_ command: [String], on host: RemoteHost) throws -> Connection {
        try Connection(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                       arguments: arguments(command, on: host))
    }

    static func run(_ command: [String], on host: RemoteHost) async throws -> Int32 {
        let connection = try start(command, on: host)
        let drain = Task { for await _ in connection.output {} }
        let errors = Task { for await _ in connection.errors {} }
        connection.closeInput()
        let status = await connection.wait()
        await drain.value
        await errors.value
        return status
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Owns a single subprocess and its pipes; has no knowledge of the wire protocol.
    @MainActor
    final class Connection {
        let output: AsyncStream<Data>
        let errors: AsyncStream<Data>
        let process: Process
        private let input: FileHandle
        private let writer = DispatchQueue(label: "whub.ssh.input")
        private let exit: Task<Int32, Never>
        private var stopping = false

        init(executable: URL, arguments: [String]) throws {
            let process = Process()
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            self.process = process
            input = stdin.fileHandleForWriting
            output = Self.read(stdout.fileHandleForReading)
            errors = Self.read(stderr.fileHandleForReading)
            let termination = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { process in
                termination.continuation.yield(process.terminationStatus)
                termination.continuation.finish()
            }
            exit = Task {
                for await status in termination.stream { return status }
                return -1
            }
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() }
            catch {
                termination.continuation.finish()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw error
            }
        }

        private static func read(_ handle: FileHandle) -> AsyncStream<Data> {
            AsyncStream { continuation in
                handle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    } else {
                        continuation.yield(data)
                    }
                }
                continuation.onTermination = { _ in
                    handle.readabilityHandler = nil
                    try? handle.close()
                }
            }
        }

        func send(_ data: Data) async throws {
            let input = input
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.async {
                    do {
                        try input.write(contentsOf: data)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }

        func closeInput() {
            let input = input
            writer.async { try? input.close() }
        }

        func stop() {
            guard !stopping else { return }
            stopping = true
            closeInput()
            let process = process
            Task {
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { process.terminate() }
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func wait() async -> Int32 { await exit.value }

        isolated deinit {
            if process.isRunning { process.terminate() }
        }
    }
}
