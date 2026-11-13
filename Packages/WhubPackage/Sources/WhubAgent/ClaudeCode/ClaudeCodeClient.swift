import Foundation

@MainActor
final class ClaudeCodeClient {
    private let process: AgentProcess

    init(executable: String? = nil) {
        process = AgentProcess(.init(name: "Claude Code", executableName: "claude", executable: executable,
                                     arguments: ["-p", "--verbose", "--input-format", "stream-json",
                                                 "--output-format", "stream-json", "--include-partial-messages",
                                                 "--permission-prompts", "host", "--permission-prompt-tool", "stdio"]))
        process.onLine = { [weak self] line in
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw AgentError(.adapterFailed, "Claude Codeから不正な応答を受信しました。")
            }
            self?.receive(message)
        }
        process.onExit = { [weak self] message in self?.fail(message) }
    }

    var onEvent: (([String: Any]) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connecting: Task<Void, Error>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private(set) var initialization: [String: Any] = [:]
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
            initialization = try await request("initialize")
        } catch {
            disconnect()
            throw error
        }
    }

    func request(_ subtype: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isConnected else { throw AgentError(.adapterFailed, "Claude Codeに接続されていません。") }
        let id = UUID().uuidString
        var request = params
        request["subtype"] = subtype
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try process.write(["type": "control_request", "request_id": id, "request": request])
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.fail("Claude Codeの応答が60秒以内に届きませんでした。再接続してください。")
                }
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError(.adapterFailed, "Claude Codeから不正な制御応答を受信しました。")
        }
        return result
    }

    func send(_ content: [[String: Any]]) throws {
        try process.write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func respond(requestID: String, response: [String: Any]) throws {
        try process.write(["type": "control_response",
                           "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    func rejectUnsupported(requestID: String) throws {
        try process.write(["type": "control_response",
                           "response": ["subtype": "error", "request_id": requestID,
                                        "error": "This request is not supported by the whub MVP client."]])
    }

    private func receive(_ message: [String: Any]) {
        if message["type"] as? String == "control_response", let response = message["response"] as? [String: Any],
           let id = response["request_id"] as? String, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if response["subtype"] as? String == "error" {
                continuation.resume(throwing: AgentError(.adapterFailed, response["error"] as? String ?? "Claude Codeの要求が失敗しました。"))
            } else {
                do {
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: response["response"] as? [String: Any] ?? [:]))
                } catch { continuation.resume(throwing: error) }
            }
        } else {
            onEvent?(message)
        }
    }

    private func fail(_ message: String) {
        disconnect(reason: message)
        onDisconnect?(message)
    }

    func disconnect(reason: String = "Claude Code接続を終了しました。") {
        process.stop()
        initialization = [:]
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: AgentError(.adapterFailed, reason)) }
    }
}
