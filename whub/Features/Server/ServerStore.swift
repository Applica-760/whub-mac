import Combine
import Foundation

// Viewはこの境界のデータと操作だけを利用し、通信処理を持たない。
@MainActor
protocol ServerBackend {
    func status(host: ServerHost, environment: ServerEnvironment) async throws -> ServerStatus
    func fetch(host: ServerHost) async throws -> [ServerCommit]
    func build(host: ServerHost, environment: ServerEnvironment, commit: String?) async throws -> ServerBuild
    func apply(host: ServerHost, environment: ServerEnvironment, build: ServerBuild) async throws -> ServerBuild
    func restart(host: ServerHost, environment: ServerEnvironment) async throws -> ServerBuild
}

struct ServerHost: Identifiable {
    let id: String
    let name: String
    let devURL: String
    let prodURL: String

    func url(for environment: ServerEnvironment) -> String {
        environment == .dev ? devURL : prodURL
    }
}

enum ServerEnvironment: String, CaseIterable {
    case dev = "Dev", prod = "Prod"
}

struct ServerCommit: Identifiable {
    let id: String
    let summary: String
    var label: String { "\(id.prefix(7)) · \(summary)" }
}

struct ServerBuild: Identifiable {
    let id: String
    let commit: String
    let createdAt: Date
    var label: String { "\(id.prefix(8)) · \(commit.prefix(7))" }
}

struct ServerPanelState {
    var checkedAt: Date?
    var fetchedAt: Date?
    var running: ServerBuild?
    var commits: [ServerCommit] = []
    var builds: [ServerBuild] = []
    var selectedCommit = ""
    var selectedBuild = ""
}

struct ServerStatus {
    let running: ServerBuild?
    let builds: [ServerBuild]
}

struct ServerLogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let hostID: String
    let environment: ServerEnvironment?
    let message: String
    var isError = false
}

enum ServerAction: String {
    case fetch = "Fetch", build = "Build", apply = "Apply", restart = "再起動"
}

@MainActor
final class ServerStore: ObservableObject {
    private struct Key: Hashable {
        let hostID: String
        let environment: ServerEnvironment
    }

    let hosts: [ServerHost]
    private let backend: any ServerBackend
    @Published var hostID: String
    @Published private var states: [Key: ServerPanelState] = [:]
    @Published private(set) var logs: [ServerLogEntry] = []
    @Published private(set) var activity: String?

    var isBusy: Bool { activity != nil }
    var host: ServerHost? { hosts.first { $0.id == hostID } }
    var visibleLogs: [ServerLogEntry] { logs.filter { $0.hostID == hostID } }
    var checkedAt: Date? { ServerEnvironment.allCases.compactMap { state($0).checkedAt }.max() }

    init(backend: any ServerBackend, hosts: [ServerHost]) {
        self.backend = backend
        self.hosts = hosts
        hostID = hosts.first?.id ?? ""
    }

    func state(_ environment: ServerEnvironment) -> ServerPanelState {
        states[Key(hostID: hostID, environment: environment)] ?? ServerPanelState()
    }

    func select(_ value: String, field: WritableKeyPath<ServerPanelState, String>, environment: ServerEnvironment) {
        states[Key(hostID: hostID, environment: environment), default: ServerPanelState()][keyPath: field] = value
    }

    func reload() async {
        guard !isBusy, let host else { return }
        activity = "Dev・Prodを確認中…"
        defer { activity = nil }
        for environment in ServerEnvironment.allCases {
            do {
                let status = try await backend.status(host: host, environment: environment)
                let key = Key(hostID: host.id, environment: environment)
                states[key, default: ServerPanelState()].running = status.running
                states[key, default: ServerPanelState()].builds = status.builds
                if !status.builds.contains(where: { $0.id == states[key]?.selectedBuild }) {
                    states[key, default: ServerPanelState()].selectedBuild = status.builds.first?.id ?? ""
                }
                states[key, default: ServerPanelState()].checkedAt = .now
                append("状態を確認しました", hostID: host.id, environment: environment)
            } catch {
                append(error.localizedDescription, hostID: host.id, environment: environment, isError: true)
            }
        }
    }

    func run(_ action: ServerAction, environment: ServerEnvironment) async {
        guard !isBusy, let host else { return }
        let key = Key(hostID: host.id, environment: environment)
        var state = states[key] ?? ServerPanelState()
        if action == .build && environment == .dev && state.selectedCommit.isEmpty { return }
        let build = state.builds.first { $0.id == state.selectedBuild }
        if action == .apply && (build == nil || state.checkedAt == nil) { return }
        if action == .restart && state.checkedAt == nil { return }
        activity = "\(environment.rawValue) · \(action.rawValue)…"
        append("\(action.rawValue)開始", hostID: host.id, environment: environment)
        defer { activity = nil }
        do {
            switch action {
            case .fetch:
                state.commits = try await backend.fetch(host: host)
                state.fetchedAt = .now
                if !state.commits.contains(where: { $0.id == state.selectedCommit }) {
                    state.selectedCommit = state.commits.first?.id ?? ""
                }
            case .build:
                let result = try await backend.build(host: host, environment: environment,
                                                     commit: environment == .dev ? state.selectedCommit : nil)
                state.builds.insert(result, at: 0)
                state.selectedBuild = result.id
                if environment == .prod { state.fetchedAt = .now }
                append("Build \(result.label) 完了（稼働版は変更なし）", hostID: host.id, environment: environment)
            case .apply:
                guard let build else { return }
                state.running = try await backend.apply(host: host, environment: environment, build: build)
                state.checkedAt = .now
            case .restart:
                state.running = try await backend.restart(host: host, environment: environment)
                state.checkedAt = .now
            }
            states[key] = state
            if action != .build { append("\(action.rawValue)完了", hostID: host.id, environment: environment) }
        } catch {
            append(error.localizedDescription, hostID: host.id, environment: environment, isError: true)
        }
    }

    func append(_ message: String, hostID: String, environment: ServerEnvironment? = nil, isError: Bool = false) {
        logs.append(ServerLogEntry(hostID: hostID, environment: environment, message: message, isError: isError))
    }
}
