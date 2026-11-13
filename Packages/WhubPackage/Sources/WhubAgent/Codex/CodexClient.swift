import Foundation

struct CodexAgentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CodexClient {
    private let process: AgentProcess

    init(executable: String? = nil) {
        process = AgentProcess(.init(name: "Codex", executableName: "codex", executable: executable,
                                     arguments: ["app-server", "--listen", "stdio://"]))
        process.onLine = { [weak self] line in
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAgentError(message: "Codexから不正な応答を受信しました。")
            }
            self?.receive(message)
        }
        process.onExit = { [weak self] message in self?.fail(message) }
    }

    var onEvent: ((String, [String: Any], Any?) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connecting: Task<Void, Error>?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    var isConnected: Bool { process.isRunning }

    func connect(directory: String) async throws {
        if let connecting { try await connecting.value }
        let cwd = URL(fileURLWithPath: directory).standardizedFileURL
        guard !isConnected || process.directory?.standardizedFileURL != cwd else { return }
        disconnect()
        let task = Task { try await startConnection(directory: cwd) }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func startConnection(directory: URL) async throws {
        try await process.start(directory: directory)
        do {
            _ = try await request("initialize", ["clientInfo": ["name": "whub_mac", "title": "whub", "version": "0.1.0"],
                                                 "capabilities": ["experimentalApi": true]])
            try process.write(["method": "initialized", "params": [:]])
        } catch {
            disconnect()
            throw error
        }
    }

    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isConnected else { throw CodexAgentError(message: "Codexに接続されていません。") }
        nextID += 1
        let id = nextID
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try process.write(["id": id, "method": method, "params": params])
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.fail("Codexの応答が60秒以内に届きませんでした。再接続してください。")
                }
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAgentError(message: "Codexから不正なRPC結果を受信しました。")
        }
        return result
    }

    func respond(id: Any, result: [String: Any]) throws {
        try process.write(["id": id, "result": result])
    }

    func rejectUnsupported(id: Any) throws {
        try process.write(["id": id, "error": ["code": -32601, "message": "This request is not supported by the whub MVP client."]])
    }

    private func receive(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            onEvent?(method, message["params"] as? [String: Any] ?? [:], message["id"])
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: CodexAgentError(message: error["message"] as? String ?? "Codexの要求が失敗しました。"))
            } else {
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func fail(_ message: String) {
        disconnect(reason: message)
        onDisconnect?(message)
    }

    func disconnect(reason: String = "Codex接続を終了しました。") {
        process.stop()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CodexAgentError(message: reason)) }
    }
}
