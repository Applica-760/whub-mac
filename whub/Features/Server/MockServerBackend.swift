import Foundation

// shortcut: 状態・成果物はメモリ内のみ。実接続時はServerBackendの実装を差し替える。
@MainActor
final class MockServerBackend: ServerBackend {
    static let hosts = [
        ServerHost(id: "a", name: "Linux A", devURL: "http://linux-a.example.com:8081", prodURL: "http://linux-a.example.com:8082"),
        ServerHost(id: "b", name: "Linux B", devURL: "http://linux-b.example.com:8081", prodURL: "http://linux-b.example.com:8082"),
    ]
    private let commits = [
        ServerCommit(id: "3d05429", summary: "main · Editorモデルを整理"),
        ServerCommit(id: "f180ba9", summary: "main · Server接続を改善"),
        ServerCommit(id: "a7c92e1", summary: "feature/server · Server管理を試作"),
    ]
    private var running: [String: ServerBuild] = [:]
    private var builds: [String: [ServerBuild]] = [:]

    func status(host: ServerHost, environment: ServerEnvironment) async throws -> ServerStatus {
        try await delay()
        return ServerStatus(running: current(host, environment), builds: builds["\(host.id)-\(environment.rawValue)"] ?? [])
    }

    func fetch(host: ServerHost) async throws -> [ServerCommit] {
        try await delay()
        return commits
    }

    func build(host: ServerHost, environment: ServerEnvironment, commit: String?) async throws -> ServerBuild {
        try await delay()
        let build = ServerBuild(id: UUID().uuidString, commit: environment == .prod ? commits[0].id : (commit ?? commits[0].id), createdAt: .now)
        builds["\(host.id)-\(environment.rawValue)", default: []].insert(build, at: 0)
        return build
    }

    func apply(host: ServerHost, environment: ServerEnvironment, build: ServerBuild) async throws -> ServerBuild {
        try await delay()
        running["\(host.id)-\(environment.rawValue)"] = build
        return build
    }

    func restart(host: ServerHost, environment: ServerEnvironment) async throws -> ServerBuild {
        try await delay()
        return current(host, environment)
    }

    private func current(_ host: ServerHost, _ environment: ServerEnvironment) -> ServerBuild {
        running["\(host.id)-\(environment.rawValue)"] ?? ServerBuild(id: "sample-01", commit: "f180ba9", createdAt: .distantPast)
    }

    private func delay() async throws {
        try await Task.sleep(for: .milliseconds(600))
        try Task.checkCancellation()
    }
}
