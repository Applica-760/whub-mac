import Foundation

struct CodexError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CodexClient {
    var onEvent: ((String, [String: Any], Any?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connecting: Task<Void, Error>?
    private var process: Process?
    private var input: FileHandle?
    private var readers: [Task<Void, Never>] = []
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var diagnostics = ""
    var isConnected: Bool { process?.isRunning == true }

    func connect(directory: String) async throws {
        if let connecting { try await connecting.value }
        let cwd = URL(fileURLWithPath: directory).standardizedFileURL
        guard !isConnected || process?.currentDirectoryURL?.standardizedFileURL != cwd else { return }
        disconnect()
        let task = Task { try await startConnection(directory: cwd) }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func startConnection(directory: URL) async throws {
        let connection = generation
        let (executable, path) = try await Self.resolveExecutable(directory: directory)
        guard generation == connection else { throw CancellationError() }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.currentDirectoryURL = directory
        child.arguments = ["app-server", "--listen", "stdio://"]
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
                    var buffer = Data()
                    for await chunk in Self.chunks(stdout.fileHandleForReading) {
                        guard let self, self.generation == connection else { return }
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 10) {
                            let line = buffer[..<newline]
                            if !line.isEmpty {
                                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                                    throw CodexError(message: "Codexから不正な応答を受信しました。")
                                }
                                self.receive(message)
                            }
                            buffer.removeSubrange(...newline)
                        }
                    }
                    self?.connectionEnded(connection)
                } catch {
                    self?.connectionEnded(connection, reason: error.localizedDescription)
                }
            },
            Task { [weak self] in
                for await chunk in Self.chunks(stderr.fileHandleForReading) {
                    guard let self, self.generation == connection else { return }
                    self.diagnostics = String((self.diagnostics + String(decoding: chunk, as: UTF8.self)).suffix(4000))
                }
            }
        ]
        do {
            _ = try await request("initialize", ["clientInfo": ["name": "whub_mac", "title": "whub", "version": "0.1.0"]])
            try write(["method": "initialized", "params": [:]])
        } catch {
            disconnect()
            throw error
        }
    }

    static func resolveExecutable(directory: URL) async throws -> (executable: String, path: String) {
        let shell = Process()
        let output = Pipe()
        // Use the same login shell as TerminalSession; startup output is not part of the result.
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", "printf '\\000%s\\000%s\\000' \"$(command -v codex)\" \"$PATH\""]
        shell.currentDirectoryURL = directory
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        let stream = chunks(output.fileHandleForReading)
        try shell.run()
        let reader = Task { await stream.reduce(into: Data()) { $0.append($1) } }
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
            throw CodexError(message: "シェルからCodexの実行パスを取得できませんでした。ターミナルの起動設定を確認してください。")
        }
        let executable = fields[fields.count - 3]
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw CodexError(message: "Codex CLIが見つかりません。新しいターミナルでcommand -v codexを確認してください。")
        }
        return (executable, fields[fields.count - 2])
    }

    // Each pipe has its own reader; a quiet stderr must not block stdout.
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

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isConnected else { throw CodexError(message: "Codexに接続されていません。") }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["id": id, "method": method, "params": params])
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.connectionEnded(self?.generation, reason: "Codexの応答が60秒以内に届きませんでした。再接続してください。")
                }
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    func respond(id: Any, result: [String: Any]) throws {
        try write(["id": id, "result": result])
    }

    func rejectUnsupported(id: Any) throws {
        try write(["id": id, "error": ["code": -32601, "message": "This request is not supported by the whub MVP client."]])
    }

    private func write(_ message: [String: Any]) throws {
        guard let input else { throw CodexError(message: "Codex接続が閉じています。") }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            onEvent?(method, message["params"] as? [String: Any] ?? [:], message["id"])
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: CodexError(message: error["message"] as? String ?? "Codexの要求が失敗しました。"))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
        }
    }

    private func connectionEnded(_ connection: UUID?, reason: String? = nil) {
        guard generation == connection else { return }
        let message = reason ?? "Codexとの接続が終了しました。" + (diagnostics.isEmpty ? "" : "\n" + diagnostics)
        disconnect(reason: message)
        onDisconnect?(message)
    }

    func disconnect(reason: String = "Codex接続を終了しました。") {
        generation = UUID()
        readers.forEach { $0.cancel() }
        readers.removeAll()
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CodexError(message: reason)) }
        diagnostics = ""
    }
}
