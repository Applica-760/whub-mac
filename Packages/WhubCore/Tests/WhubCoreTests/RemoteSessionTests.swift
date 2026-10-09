// 検証する内容:
// - 同梱Pythonへの連続・並行要求が同一プロセスで処理され、毎回起動されない。
// - 注入直後の入力、分割・連結・順序逆転した応答を正しく読み取る。
// - 起動失敗・切断・期限超過・キャンセルで要求が残らず、終了時にプロセスが終了する。
// - スクリプト送信が詰まっていてもキャンセルで起動期限前にプロセスを終了する。
// - JSON-RPCエラー後にも接続を利用でき、stderrの大量出力で停止しない。
// - Project／Worktree相当のルートで直下だけ取得し、隠しファイルの表示条件とリンク種別を保つ。
// - 本文の正確な復元、1 MiB境界、非UTF-8・バイナリ・特殊ファイル・リンク・ルート外の拒否を検証する。
// 限界: ローカル検証はSSH認証・実ネットワーク断を保証しない。
// 実SSH検証はWHUB_TEST_HOST_NAMEで登録済みHost.nameを指定した場合のみ実行する。
// WHUB_TEST_PROJECT_NAMEで既存ディレクトリを指定可能。省略時は保存済みProjectから選ぶ。
// 接続情報はアプリのHostStoreから取得し、保存レコードの追加・変更は行わない。
import Foundation
import Darwin
import Testing
@testable import WhubCore

@Suite @MainActor
struct RemoteSessionTests {
    private func process() throws -> SSH.Connection {
        try SSH.Connection(executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "exec " + ["/usr/bin/python3", "-u", "-c", RemoteSession.bootstrap].map(SSH.quote).joined(separator: " ")])
    }

    @Test func reusesProcessAndSurvivesRPCError() async throws {
        let connection = try process()
        let session = try await RemoteSession.connect(connection: connection, source: RemoteSession.agent)
        let pid = try await session.ping()
        #expect(pid == Int(connection.process.processIdentifier))
        for _ in 0..<20 { #expect(try await session.ping() == pid) }
        async let first = session.ping()
        async let second = session.ping()
        let results = try await [first, second]
        #expect(results == [pid, pid])
        await #expect(throws: RemoteSessionError.remote(-32601, "Method not found")) {
            try await session.request("unknown")
        }
        #expect(try await session.ping() == pid)
        await session.close()
        #expect(!connection.process.isRunning)
        #expect(await connection.wait() == 0)
        await #expect(throws: RemoteSessionError.disconnected) { try await session.ping() }
    }

    @Test func injectionPreservesFollowingBytes() async throws {
        let connection = try process()
        let source = try RemoteSession.agent
        let request = Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8) + Data([10])
        // Deliberately write source and first request together: bootstrap must not lose buffered bytes.
        try await connection.send(Data("\(source.count)\n".utf8) + source + request)
        connection.closeInput()
        var output = Data()
        for await data in connection.output { output.append(data) }
        let response = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(response["id"] as? Int == 9)
        #expect(await connection.wait() == 0)
    }

    @Test func fragmentedCombinedAndReorderedResponses() async throws {
        let source = Data("""
        import sys, json, time
        first = json.loads(sys.stdin.buffer.readline())
        print(json.dumps({"jsonrpc":"2.0", "id":first["id"], "result":{"pid":1}}), flush=True)
        requests = [json.loads(sys.stdin.buffer.readline()) for _ in range(2)]
        payload = b"".join((json.dumps({"jsonrpc":"2.0", "id":r["id"], "result":r["method"]}) + "\\n").encode() for r in reversed(requests))
        sys.stdout.buffer.write(payload[:7]); sys.stdout.buffer.flush()
        time.sleep(0.02)
        sys.stdout.buffer.write(payload[7:]); sys.stdout.buffer.flush()
        sys.stdin.buffer.read()
        """.utf8)
        let connection = try process()
        let session = try await RemoteSession.connect(connection: connection, source: source)
        async let first = session.request("first", timeout: .seconds(2))
        async let second = session.request("second", timeout: .seconds(2))
        let values = try await [first, second]
        #expect(try JSONDecoder().decode(String.self, from: values[0]) == "first")
        #expect(try JSONDecoder().decode(String.self, from: values[1]) == "second")
        await session.close()
        #expect(!connection.process.isRunning)
    }

    @Test func pendingRequestsFailOnDisconnectAndTimeout() async throws {
        for disconnect in [true, false] {
            let source = Data("""
            import sys, json, time
            r = json.loads(sys.stdin.buffer.readline())
            print(json.dumps({"jsonrpc":"2.0", "id":r["id"], "result":{"pid":1}}), flush=True)
            sys.stderr.write("x" * 100000); sys.stderr.flush()
            sys.stdin.buffer.readline()
            \(disconnect ? "sys.exit(0)" : "time.sleep(60)")
            """.utf8)
            let connection = try process()
            let session = try await RemoteSession.connect(connection: connection, source: source)
            let expected: RemoteSessionError = disconnect ? .disconnected : .timedOut
            async let a: Void = expectFailure(session, error: expected)
            async let b: Void = expectFailure(session, error: expected)
            await a
            await b
            await session.close()
            #expect(!connection.process.isRunning)
            #expect(session.diagnostics.count == 16_384)
        }
    }

    private func expectFailure(_ session: RemoteSession, error: RemoteSessionError) async {
        await #expect(throws: error) { try await session.ping(timeout: .milliseconds(150)) }
    }

    @Test func startupFailureAndCancellation() async throws {
        #expect(throws: (any Error).self) {
            try SSH.Connection(executable: URL(fileURLWithPath: "/nonexistent/whub-test"), arguments: [])
        }
        let dead = try process()
        await #expect(throws: RemoteSessionError.disconnected) {
            try await RemoteSession.connect(connection: dead, source: Data("raise SystemExit(1)".utf8))
        }
        #expect(await dead.wait() == 1)
        let sleeping = try process()
        await #expect(throws: RemoteSessionError.timedOut) {
            try await RemoteSession.connect(connection: sleeping, source: Data("import time; time.sleep(60)".utf8), timeout: .milliseconds(100))
        }
        _ = await sleeping.wait()
        #expect(!sleeping.process.isRunning)

        let source = Data("""
        import sys, json, time
        for line in sys.stdin.buffer:
            r = json.loads(line)
            if r["method"] == "slow": time.sleep(0.2)
            print(json.dumps({"jsonrpc":"2.0", "id":r["id"], "result":{"pid":1}}), flush=True)
        """.utf8)
        let connection = try process()
        let session = try await RemoteSession.connect(connection: connection, source: source)
        let request = Task { try await session.request("slow") }
        try await Task.sleep(for: .milliseconds(30))
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await session.ping() == 1)
        await session.close()
    }

    @Test func cancellationStopsBlockedInjection() async throws {
        let directory = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        // Read only the length line, then leave the source bytes in the pipe.
        let connection = try SSH.Connection(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", """
            import os, sys, time
            b = b''
            while not b.endswith(b'\\n'): b += os.read(0, 1)
            open(sys.argv[1], 'w').close()
            time.sleep(60)
            """, ready.path]
        )
        let attempt = Task {
            try await RemoteSession.connect(
                connection: connection, source: Data(repeating: 32, count: 1_048_576), timeout: .seconds(10)
            )
        }
        defer { attempt.cancel(); connection.stop() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard ContinuousClock.now < deadline else { throw RemoteSessionError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(connection.process.isRunning)
        let start = ContinuousClock.now
        attempt.cancel()
        do {
            let session = try await attempt.value
            await session.close()
            Issue.record("送信中のキャンセル後に接続が成功しました。")
        } catch {
            #expect(start.duration(to: .now) < .seconds(5))
        }
        #expect(!connection.process.isRunning)
    }

    private func fixture() throws -> URL {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = package.appendingPathComponent(".build/remote-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func directoryRootsAndBoundaries() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let project = fixture.appendingPathComponent("projects/demo")
        let worktree = fixture.appendingPathComponent("worktrees/demo-39")
        for directory in [project.appendingPathComponent("child"), worktree, project.appendingPathComponent(".git")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in [".env", ".gitignore", ".DS_Store", "note '日本語\n.txt", "child/nested.txt"] {
            try Data("hello".utf8).write(to: project.appendingPathComponent(name))
        }
        try Data("worktree".utf8).write(to: worktree.appendingPathComponent("only.txt"))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("link"),
                                                 withDestinationURL: project.appendingPathComponent("child"))
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("alias"), withDestinationURL: project)
        let connection = try process()
        let session = try await RemoteSession.connect(connection: connection, source: RemoteSession.agent)
        let pid = try await session.ping()
        let entries = try await session.listDirectory(root: project.path)
        #expect(Set(entries.map(\.name)) == Set(["child", ".env", ".gitignore", "note '日本語\n.txt", "link"]))
        #expect(entries.first { $0.name == "child" }?.kind == .directory)
        #expect(entries.first { $0.name == "link" }?.kind == .symlink)
        #expect(try await session.listDirectory(root: project.path, path: "child").map(\.name) == ["nested.txt"])
        #expect(try await session.listDirectory(root: worktree.path).map(\.name) == ["only.txt"])
        #expect(try await session.readText(root: project.path, path: "note '日本語\n.txt") == "hello")
        #expect(try await session.readText(root: worktree.path, path: "only.txt") == "worktree")
        for path in ["../demo/child/nested.txt", "/etc/passwd"] {
            await expectReadFailure(session, root: project.path, path: path, code: -32001)
        }
        await expectReadFailure(session, root: project.path, path: "link/nested.txt", code: -32002)
        await expectReadFailure(session, root: fixture.appendingPathComponent("alias").path, path: ".env", code: -32002)
        await #expect(throws: RemoteSessionError.remote(-32002, "シンボリックリンクは辿れません。")) {
            try await session.listDirectory(root: project.path, path: "link")
        }
        #expect(try await session.ping() == pid)
        await session.close()
    }

    @Test func textLimitsTypesAndErrors() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        // Tabs expand in JSON: the permitted body must still pass the larger wire-frame limit.
        let atLimit = String(repeating: "\t", count: 1_048_576)
        let unicode = "日本語 😀 ' \\\r\nsecond line\n"
        for (name, data) in [
            "empty": Data(), "unicode": Data(unicode.utf8), "limit": Data(atLimit.utf8),
            "too-large": Data(repeating: 65, count: 1_048_577), "non-utf8": Data([0xff]),
            "binary": Data([65, 0, 66]), "control": Data([1]), "denied": Data("private".utf8),
        ] {
            try data.write(to: fixture.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.appendingPathComponent("denied").path)
        try FileManager.default.createSymbolicLink(at: fixture.appendingPathComponent("link"),
                                                 withDestinationURL: fixture.appendingPathComponent("unicode"))
        #expect(mkfifo(fixture.appendingPathComponent("fifo").path, 0o600) == 0)
        let connection = try process()
        let session = try await RemoteSession.connect(connection: connection, source: RemoteSession.agent)
        let pid = try await session.ping()
        #expect(try await session.readText(root: fixture.path, path: "empty") == "")
        #expect(try await session.readText(root: fixture.path, path: "unicode") == unicode)
        #expect(try await session.readText(root: fixture.path, path: "limit") == atLimit)
        for (path, code) in [("too-large", -32004), ("non-utf8", -32005), ("binary", -32006),
                             ("control", -32006), ("link", -32002), ("fifo", -32003),
                             ("", -32003), ("missing", -32007), ("denied", -32007)] {
            await expectReadFailure(session, root: fixture.path, path: path, code: code)
        }
        #expect(try await session.listDirectory(root: fixture.path).first { $0.name == "fifo" }?.kind == .other)
        #expect(try await session.ping() == pid)
        await session.close()
    }

    private func expectReadFailure(_ session: RemoteSession, root: String, path: String, code: Int) async {
        do {
            _ = try await session.readText(root: root, path: path)
            Issue.record("拒否すべきファイルを取得しました: \(path)")
        } catch RemoteSessionError.remote(let actual, _) {
            #expect(actual == code)
        } catch {
            Issue.record("取得エラーの代わりに通信自体が失敗しました: \(error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHUB_TEST_HOST_NAME"] != nil))
    func actualUbuntuSSH() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["WHUB_TEST_HOST_NAME"])
        let container = try Container.make()
        container.mainContext.autosaveEnabled = false
        let host = try #require(
            HostStore(context: container.mainContext).fetchHosts().first { $0.name == name } as? RemoteHost,
            "指定した名前のRemoteHostが保存されていません。"
        )
        let session = try await RemoteSession.connect(to: host)
        let pid = try await session.ping()
        for _ in 0..<20 { #expect(try await session.ping() == pid) }
        let projects = try ProjectStore(context: container.mainContext).fetchProjects().filter { $0.host.name == name }
        let projectEntries = try await session.listDirectory(root: host.projectsPath)
        let projectName = try #require(
            ProcessInfo.processInfo.environment["WHUB_TEST_PROJECT_NAME"]
                ?? projects.first { project in
                    projectEntries.contains { $0.name == project.name && $0.kind == .directory }
                }?.name,
            "登録済みProjectがない場合はWHUB_TEST_PROJECT_NAMEで既存ディレクトリを指定してください。"
        )
        #expect(projectEntries.contains { $0.name == projectName && $0.kind == .directory })
        guard projectEntries.contains(where: { $0.name == projectName && $0.kind == .directory }) else {
            await session.close()
            return
        }
        let root = (host.projectsPath as NSString).appendingPathComponent(projectName)
        let entries = try await session.listDirectory(root: root)
        let candidates = entries.filter {
            $0.kind == .file && ["md", "txt", "py", "swift", "toml", "json"].contains(($0.name as NSString).pathExtension)
        }.sorted { $0.name < $1.name }
        let file = try #require(candidates.first { $0.name == "README.md" } ?? candidates.first,
                               "Project直下に検証用テキストがありません。")
        let text = try await session.readText(root: root, path: file.name)
        #expect(text.utf8.count <= 1_048_576)
        print("Remote read verified: \(projectName)/\(file.name), \(text.utf8.count) bytes; entries: \(entries.count)")
        let worktrees = try await session.listDirectory(root: host.worktreesPath)
        let prefix = projectName + "-"
        if let entry = worktrees.first(where: {
            $0.kind == .directory && $0.name.hasPrefix(prefix)
                && (Int($0.name.dropFirst(prefix.count)) ?? 0) > 0
        }) {
            let worktreeRoot = (host.worktreesPath as NSString).appendingPathComponent(entry.name)
            _ = try await session.listDirectory(root: worktreeRoot)
            print("Remote Worktree root verified: \(entry.name)")
        } else {
            print("Remote Worktree read not exercised: no matching Worktree exists.")
        }
        #expect(try await session.ping() == pid)
        await session.close()
    }
}
