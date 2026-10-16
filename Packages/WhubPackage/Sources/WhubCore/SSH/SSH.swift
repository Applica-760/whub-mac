import Foundation
import Darwin

public enum SSHError: LocalizedError {
    case emptyCommand, invalidHostname, invalidUser, invalidPort, invalidIdentityFile
    case disconnected, timedOut, invalidForwarding
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand: "SSH command is required."
        case .invalidHostname: "SSH hostname is invalid."
        case .invalidUser: "SSH user is invalid."
        case .invalidPort: "SSH port must be between 1 and 65535."
        case .invalidIdentityFile: "SSH identity path contains a NUL character."
        case .disconnected: "SSH connection is closed."
        case .timedOut: "SSH connection timed out."
        case .invalidForwarding: "SSH forwarding requires valid ports and a destination host."
        case let .operationFailed(message): message
        }
    }
}

@MainActor
public enum SSH {
    public struct Configuration: Sendable, Equatable {
        public let hostname: String
        public let user: String
        public let port: Int
        public let identityFile: String

        public init(hostname: String, user: String, port: Int = 22, identityFile: String = "") throws {
            try SSH.validate(hostname: hostname, user: user, port: port)
            guard !identityFile.contains("\0") else { throw SSHError.invalidIdentityFile }
            self.hostname = hostname
            self.user = user
            self.port = port
            self.identityFile = identityFile
        }

        var destination: String { "\(user)@\(hostname)" }
    }

    public nonisolated static func validate(hostname: String, user: String, port: Int) throws {
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

    static func arguments(for configuration: Configuration) -> [String] {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                         "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                         "-p", String(configuration.port)]
        if !configuration.identityFile.isEmpty { arguments += ["-i", configuration.identityFile] }
        return arguments
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Owns a single subprocess and its pipes; has no knowledge of the wire protocol.
    @MainActor
    public final class Connection {
        public let output: AsyncStream<Data>
        public let errors: AsyncStream<Data>
        let process: Process
        private let input: FileHandle
        private let writer = DispatchQueue(label: "whub.ssh.input")
        private let exit: Task<Int32, Never>
        private var stopping = false

        init(executable: URL, arguments: [String]) throws {
            let process = Process()
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            // A cancelled write must throw EPIPE rather than terminate the app.
            guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
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

        public func send(_ data: Data) async throws {
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

        public func closeInput() {
            let input = input
            writer.async { try? input.close() }
        }

        public func stop() {
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

        public func wait() async -> Int32 { await exit.value }

        func result() async throws -> (status: Int32, output: Data, errors: Data) {
            func collect(_ stream: AsyncStream<Data>) async -> Data {
                var result = Data()
                for await chunk in stream {
                    result.append(chunk)
                    result = Data(result.suffix(16_384))
                }
                return result
            }
            let output = Task { await collect(self.output) }
            let errors = Task { await collect(self.errors) }
            closeInput()
            return try await withTaskCancellationHandler {
                let status = await wait()
                let result = await (status, output.value, errors.value)
                try Task.checkCancellation()
                return result
            } onCancel: {
                Task { @MainActor in self.stop() }
            }
        }

        isolated deinit {
            if process.isRunning { process.terminate() }
        }
    }
}
