import Foundation
import CoreFoundation

public enum RemoteSessionError: LocalizedError, Equatable {
    case disconnected, timedOut, invalidMessage, missingAgent
    case remote(Int, String)

    public var errorDescription: String? {
        switch self {
        case .disconnected: "リモート接続が切断されています。"
        case .timedOut: "リモートからの応答がタイムアウトしました。"
        case .invalidMessage: "リモートからの応答が不正か、通信上限を超えています。"
        case .missingAgent: "同梱のリモート処理を読み込めません。"
        case let .remote(_, message): message
        }
    }
}

public struct RemoteFileEntry: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable { case file, directory, symlink, other }
    public let name: String
    public let kind: Kind
}

@MainActor
public final class RemoteSession {
    // Read exactly the script bytes from the same buffered reader used by the agent.
    static let bootstrap = """
    import sys
    n = int(sys.stdin.buffer.readline(32))
    if not 0 < n <= 1048576: raise ValueError("Invalid script length")
    source = sys.stdin.buffer.read(n)
    if len(source) != n: raise EOFError("Incomplete script")
    exec(compile(source, "<whub-remote-agent>", "exec"), {"__name__": "__main__"})
    """

    static var agent: Data {
        get throws {
            guard let agentURL = Bundle.module.url(forResource: "remote_agent", withExtension: "py"),
                  let filesURL = Bundle.module.url(forResource: "remote_files", withExtension: "py") else {
                throw RemoteSessionError.missingAgent
            }
            let files = try Data(contentsOf: filesURL).base64EncodedString()
            // Register the bundled module in memory: no remote installation or temporary file.
            let loader = """
            import base64, sys, types
            module = types.ModuleType("remote_files")
            exec(compile(base64.b64decode("\(files)"), "remote_files.py", "exec"), module.__dict__)
            sys.modules["remote_files"] = module
            """
            return Data((loader + "\n").utf8) + (try Data(contentsOf: agentURL))
        }
    }

    private static let maxResponseBytes = 8 * 1_048_576

    private let connection: SSH.Connection
    private var reader: Task<Void, Never>?
    private var errorReader: Task<Void, Never>?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var closed = false
    public private(set) var diagnostics = Data()
    public let notifications: AsyncStream<Data>
    private let notificationSink: AsyncStream<Data>.Continuation

    private init(connection: SSH.Connection) {
        self.connection = connection
        let notifications = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.notifications = notifications.stream
        notificationSink = notifications.continuation
        reader = Task { [weak self, output = connection.output] in
            for await data in output {
                guard let self, !self.closed else { break }
                do { try self.receive(data) }
                catch { self.fail(error) }
            }
            self?.fail(RemoteSessionError.disconnected)
        }
        errorReader = Task { [weak self, errors = connection.errors] in
            for await data in errors {
                guard let self else { break }
                self.diagnostics.append(data)
                self.diagnostics = Data(self.diagnostics.suffix(16_384))
            }
        }
    }

    public static func connect(to host: RemoteHost, timeout: Duration = .seconds(10)) async throws -> RemoteSession {
        let source = try agent
        let connection = try SSH.start(["python3", "-u", "-c", bootstrap], on: host)
        return try await connect(connection: connection, source: source, timeout: timeout)
    }

    static func connect(connection: SSH.Connection, source: Data, timeout: Duration = .seconds(10)) async throws -> RemoteSession {
        let session = RemoteSession(connection: connection)
        let startupDeadline = Task { [weak session] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            session?.fail(RemoteSessionError.timedOut)
        }
        defer { startupDeadline.cancel() }
        do {
            guard !source.isEmpty, source.count <= 1_048_576 else { throw RemoteSessionError.invalidMessage }
            try await connection.send(Data("\(source.count)\n".utf8) + source)
            _ = try await session.ping(timeout: timeout)
            return session
        } catch {
            session.fail(error)
            throw error
        }
    }

    public func ping(timeout: Duration = .seconds(10)) async throws -> Int {
        struct Reply: Decodable { let pid: Int }
        let data = try await request("ping", timeout: timeout)
        return try JSONDecoder().decode(Reply.self, from: data).pid
    }

    public func listDirectory(root: String, path: String = "", timeout: Duration = .seconds(10)) async throws -> [RemoteFileEntry] {
        let data = try await request("listDirectory", params: ["root": root, "path": path], timeout: timeout)
        return try JSONDecoder().decode([RemoteFileEntry].self, from: data)
    }

    public func readText(root: String, path: String, timeout: Duration = .seconds(10)) async throws -> String {
        struct Reply: Decodable { let text: String }
        let data = try await request("readText", params: ["root": root, "path": path], timeout: timeout)
        return try JSONDecoder().decode(Reply.self, from: data).text
    }

    func request(_ method: String, params: [String: String] = [:], timeout: Duration = .seconds(10)) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw RemoteSessionError.disconnected }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]) + Data([10])
        guard data.count <= 1_048_576 else { throw RemoteSessionError.invalidMessage }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.fail(RemoteSessionError.timedOut)
                }
                Task { [weak self, connection] in
                    do { try await connection.send(data) }
                    catch { self?.fail(error) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, with: .failure(CancellationError())) }
        }
    }

    private func receive(_ data: Data) throws {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count < Self.maxResponseBytes,
                  let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["jsonrpc"] as? String == "2.0" else { throw RemoteSessionError.invalidMessage }
            if object["id"] == nil, object["method"] is String {
                if case .dropped = notificationSink.yield(line) {
                    throw RemoteSessionError.invalidMessage
                }
                continue
            }
            guard let number = object["id"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue),
                  (object["result"] != nil) != (object["error"] != nil) else {
                throw RemoteSessionError.invalidMessage
            }
            let id = number.intValue
            if let error = object["error"] as? [String: Any],
               let code = error["code"] as? Int, let message = error["message"] as? String {
                complete(id, with: .failure(RemoteSessionError.remote(code, message)))
            } else if let result = object["result"] {
                complete(id, with: .success(try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])))
            } else { throw RemoteSessionError.invalidMessage }
        }
        guard buffer.count < Self.maxResponseBytes else { throw RemoteSessionError.invalidMessage }
    }

    private func complete(_ id: Int, with result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        for id in Array(pending.keys) { complete(id, with: .failure(error)) }
        notificationSink.finish()
        connection.stop()
        reader?.cancel()
    }

    public func close() async {
        fail(RemoteSessionError.disconnected)
        _ = await connection.wait()
        await errorReader?.value
    }

    isolated deinit {
        reader?.cancel()
        errorReader?.cancel()
        for continuation in pending.values { continuation.resume(throwing: RemoteSessionError.disconnected) }
        for deadline in deadlines.values { deadline.cancel() }
        notificationSink.finish()
        connection.stop()
    }
}
