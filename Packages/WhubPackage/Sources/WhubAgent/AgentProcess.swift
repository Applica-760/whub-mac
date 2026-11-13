import Foundation

@MainActor
final class AgentProcess {
    struct Command {
        let name: String
        let executableName: String
        let executable: String?
        let arguments: [String]
    }

    struct LineBuffer {
        private var buffer = Data()
        private var searchStart = 0

        mutating func append(_ chunk: Data, receive: (Data) throws -> Void) rethrows {
            buffer.append(chunk)
            while let newline = buffer[searchStart...].firstIndex(of: 10) {
                if newline > buffer.startIndex { try receive(Data(buffer[..<newline])) }
                buffer.removeSubrange(...newline)
                searchStart = buffer.startIndex
            }
            searchStart = buffer.endIndex
        }
    }

    var onLine: ((Data) throws -> Void)?
    var onExit: ((String) -> Void)?
    private let command: Command
    private var process: Process?
    private var input: FileHandle?
    private var readers: [Task<Void, Never>] = []
    private var generation = UUID()
    private var diagnostics = ""
    var isRunning: Bool { process?.isRunning == true }
    var directory: URL? { process?.currentDirectoryURL }

    init(_ command: Command) {
        self.command = command
    }

    func start(directory: URL) async throws {
        let connection = generation
        let (executable, path): (String, String)
        if let configured = command.executable {
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
                throw AgentError(.adapterFailed, "\(command.name)の実行ファイルには実行可能な絶対パスを指定してください。")
            }
            (executable, path) = (configured, ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        } else {
            (executable, path) = try await Self.resolveExecutable(command, directory: directory)
        }
        guard generation == connection else { throw CancellationError() }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.currentDirectoryURL = directory
        child.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        readers = [
            Task { [weak self] in
                do {
                    var buffer = LineBuffer()
                    for await chunk in Self.chunks(stdout.fileHandleForReading) {
                        guard let self, self.generation == connection else { return }
                        try buffer.append(chunk) { try self.onLine?($0) }
                    }
                    self?.ended(connection)
                } catch {
                    self?.ended(connection, reason: error.localizedDescription)
                }
            },
            Task { [weak self] in
                for await chunk in Self.chunks(stderr.fileHandleForReading) {
                    guard let self, self.generation == connection else { return }
                    self.diagnostics = String((self.diagnostics + String(decoding: chunk, as: UTF8.self)).suffix(4000))
                }
            }
        ]
    }

    static func resolveExecutable(_ command: Command, directory: URL) async throws -> (executable: String, path: String) {
        let shell = Process()
        let output = Pipe()
        let script = "printf '\\000%s\\000%s\\000' \"$(command -v \(command.executableName))\" \"$PATH\""
        #if os(macOS)
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", script]
        #else
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        #endif
        shell.currentDirectoryURL = directory
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        let stream = chunks(output.fileHandleForReading)
        try shell.run()
        let reader = Task {
            var data = Data()
            for await chunk in stream { data.append(chunk) }
            return data
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            reader.cancel()
        }
        defer {
            timeout.cancel()
            if shell.isRunning { shell.terminate() }
            try? output.fileHandleForReading.close()
        }
        let data = await reader.value
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        guard fields.count >= 4 else {
            throw AgentError(.adapterFailed, "シェルから\(command.name)の実行パスを取得できませんでした。ターミナルの起動設定を確認してください。")
        }
        let executable = fields[fields.count - 3]
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentError(.adapterFailed,
                             "\(command.name) CLIが見つかりません。新しいターミナルでcommand -v \(command.executableName)を確認してください。")
        }
        return (executable, fields[fields.count - 2])
    }

    nonisolated private static func chunks(_ handle: FileHandle) -> AsyncStream<Data> {
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
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    func write(_ message: [String: Any]) throws {
        guard let input else { throw AgentError(.adapterFailed, "\(command.name)接続が閉じています。") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func ended(_ connection: UUID, reason: String? = nil) {
        guard generation == connection else { return }
        let message = reason ?? "\(command.name)との接続が終了しました。" + (diagnostics.isEmpty ? "" : "\n" + diagnostics)
        stop()
        onExit?(message)
    }

    func stop() {
        generation = UUID()
        readers.forEach { $0.cancel() }
        readers.removeAll()
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        diagnostics = ""
    }
}
