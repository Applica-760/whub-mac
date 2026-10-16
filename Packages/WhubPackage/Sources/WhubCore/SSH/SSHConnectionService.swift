import Darwin
import Foundation

/// Owns one authenticated SSH transport; commands and forwards share its control socket.
@MainActor
public final class SSHConnectionService {
    public let configuration: SSH.Configuration
    public var isConnected: Bool { closing == nil && master.process.isRunning }
    public private(set) var disconnectionError: (any Error)?
    public var onDisconnect: ((any Error) -> Void)? {
        didSet {
            if let disconnectionError { onDisconnect?(disconnectionError) }
        }
    }

    private let master: SSH.Connection
    private let controlDirectory: URL
    private var socketPath: String { controlDirectory.appendingPathComponent("ctl").path }
    private var commands: [ObjectIdentifier: SSH.Connection] = [:]
    private var diagnostics = Data()
    private var readers: [Task<Void, Never>] = []
    private var monitor: Task<Void, Never>?
    private var closing: Task<Void, Never>?

    init(configuration: SSH.Configuration, master: SSH.Connection, controlDirectory: URL) {
        self.configuration = configuration
        self.master = master
        self.controlDirectory = controlDirectory
        readers = [
            Task { for await _ in master.output {} },
            Task { [weak self] in
                for await data in master.errors {
                    guard let self else { return }
                    self.diagnostics.append(data)
                    self.diagnostics = Data(self.diagnostics.suffix(16_384))
                }
            },
        ]
        monitor = Task { [weak self] in
            _ = await master.wait()
            guard let self, self.closing == nil else { return }
            let message = String(decoding: self.diagnostics, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let error: SSHError = message.isEmpty ? .disconnected : .operationFailed(message)
            self.disconnectionError = error
            self.onDisconnect?(error)
            await self.close()
        }
    }

    public static func connect(configuration: SSH.Configuration) async throws -> SSHConnectionService {
        let directory = try makeControlDirectory()
        let master: SSH.Connection
        do {
            master = try SSH.Connection(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments:
                SSH.arguments(for: configuration) + [
                    "-M", "-N", "-S", directory.appendingPathComponent("ctl").path,
                    "-o", "ControlPersist=no", "-o", "ClearAllForwardings=yes",
                    "-o", "RemoteCommand=none", configuration.destination,
                ])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let service = SSHConnectionService(configuration: configuration, master: master, controlDirectory: directory)
        do {
            let deadline = ContinuousClock.now + .seconds(10)
            while !FileManager.default.fileExists(atPath: service.socketPath) {
                try Task.checkCancellation()
                guard service.isConnected else { throw service.disconnectionError ?? SSHError.disconnected }
                guard ContinuousClock.now < deadline else { throw SSHError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await service.control(["-O", "check"])
            return service
        } catch {
            await service.close()
            throw error
        }
    }

    /// Starts a command channel without falling back to a new SSH authentication.
    public func startCommand(_ command: [String]) throws -> SSH.Connection {
        guard isConnected else { throw SSHError.disconnected }
        guard !command.isEmpty, !command.contains(where: { $0.contains("\0") }) else { throw SSHError.emptyCommand }
        let connection = try SSH.Connection(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments:
            sharedArguments + ["-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none",
                               configuration.destination, command.map(SSH.quote).joined(separator: " ")])
        track(connection)
        return connection
    }

    public func run(_ command: [String]) async throws -> Int32 {
        let connection = try startCommand(command)
        return try await connection.result().status
    }

    public func forward(localPort: Int, remoteHost: String = "127.0.0.1", remotePort: Int) async throws {
        let specification = try forwarding(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
        try await control(["-O", "forward", "-L", specification])
    }

    public func cancelForward(localPort: Int, remoteHost: String = "127.0.0.1", remotePort: Int) async throws {
        let specification = try forwarding(localPort: localPort, remoteHost: remoteHost, remotePort: remotePort)
        try await control(["-O", "cancel", "-L", specification])
    }

    public func close() async {
        if let closing { await closing.value; return }
        disconnectionError = disconnectionError ?? SSHError.disconnected
        let children = Array(commands.values)
        commands.removeAll()
        master.stop()
        children.forEach { $0.stop() }
        let task = Task { [master, readers, controlDirectory] in
            _ = await master.wait()
            for child in children { _ = await child.wait() }
            for reader in readers { await reader.value }
            try? FileManager.default.removeItem(at: controlDirectory)
        }
        closing = task
        await task.value
    }

    private var sharedArguments: [String] {
        SSH.arguments(for: configuration) + ["-S", socketPath, "-o", "ControlMaster=no", "-o", "ControlPersist=no",
                                            "-o", "ProxyCommand=/usr/bin/false"]
    }

    private func control(_ arguments: [String]) async throws {
        guard isConnected else { throw SSHError.disconnected }
        let connection = try SSH.Connection(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                                            arguments: sharedArguments + arguments + [configuration.destination])
        track(connection)
        let result = try await connection.result()
        guard result.status == 0 else {
            throw SSHError.operationFailed(String(decoding: result.errors, as: UTF8.self))
        }
        try Task.checkCancellation()
        guard isConnected else { throw SSHError.disconnected }
    }

    private func track(_ connection: SSH.Connection) {
        let id = ObjectIdentifier(connection)
        commands[id] = connection
        Task { [weak self] in
            _ = await connection.wait()
            self?.commands.removeValue(forKey: id)
        }
    }

    private func forwarding(localPort: Int, remoteHost: String, remotePort: Int) throws -> String {
        guard (1...65535).contains(localPort), (1...65535).contains(remotePort),
              !remoteHost.isEmpty, !remoteHost.hasPrefix("-"),
              remoteHost.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !remoteHost.contains("["), !remoteHost.contains("]"), !remoteHost.contains("@") else {
            throw SSHError.invalidForwarding
        }
        let host = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        return "127.0.0.1:\(localPort):\(host):\(remotePort)"
    }

    static func makeControlDirectory() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("whub-ssh.XXXXXX").path.utf8CString)
        // macOS Unix-domain socket paths must fit in sockaddr_un.sun_path (104 bytes).
        guard template.count + 4 <= 104, let path = mkdtemp(&template) else {
            throw SSHError.operationFailed("Unable to create a private SSH control directory.")
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    isolated deinit {
        master.stop()
        for command in commands.values { command.stop() }
    }
}
