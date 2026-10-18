import Combine
import Foundation
import SwiftData
import WhubClient
import WhubCore

enum ServerEnvironment: String, CaseIterable {
    case dev = "Dev", prod = "Prod"

    func url(for host: RemoteHost) -> String? {
        self == .dev ? host.devServerURL : host.prodServerURL
    }
}

extension ManagerAPI.Commit {
    var label: String { "\(id.prefix(7)) · \(summary)" }
}

extension ManagerAPI.Build {
    var label: String { "\(id.prefix(8)) · \(commit.prefix(7))" }
}

struct ServerPanelState {
    var checkedAt: Date?
    var fetchedAt: Date?
    var running: ManagerAPI.Build?
    var commits: [ManagerAPI.Commit] = []
    var builds: [ManagerAPI.Build] = []
    var selectedCommit = ""
    var selectedBuild = ""
    var locked = false
    var error: String?
}

struct ServerLogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let hostID: PersistentIdentifier
    let environment: ServerEnvironment
    let message: String
    var isError = false
}

enum ServerAction: String {
    case fetch = "Fetch", build = "Build", apply = "Apply", restart = "再起動"
}

@MainActor
final class ServerStore: ObservableObject {
    private struct Key: Hashable {
        let hostID: PersistentIdentifier
        let environment: ServerEnvironment
        let url: String?
    }

    @Published private(set) var hosts: [RemoteHost] = []
    @Published var hostID: PersistentIdentifier?
    @Published private var states: [Key: ServerPanelState] = [:]
    @Published private(set) var logs: [ServerLogEntry] = []
    @Published private(set) var activity: String?
    private var servers: RemoteServerStore?

    var isBusy: Bool { activity != nil }
    var host: RemoteHost? { hosts.first { $0.persistentModelID == hostID } }
    var visibleLogs: [ServerLogEntry] { logs.filter { $0.hostID == hostID } }
    var checkedAt: Date? { ServerEnvironment.allCases.compactMap { state($0).checkedAt }.max() }

    func configure(hosts: [RemoteHost], servers: RemoteServerStore) {
        self.hosts = hosts
        self.servers = servers
        if !hosts.contains(where: { $0.persistentModelID == hostID }) { hostID = hosts.first?.persistentModelID }
    }

    private func key(_ host: RemoteHost, _ environment: ServerEnvironment) -> Key {
        Key(hostID: host.persistentModelID, environment: environment, url: environment.url(for: host))
    }

    func state(_ environment: ServerEnvironment) -> ServerPanelState {
        guard let host else { return ServerPanelState() }
        return states[key(host, environment)] ?? ServerPanelState()
    }

    func select(_ value: String, field: WritableKeyPath<ServerPanelState, String>, environment: ServerEnvironment) {
        guard let host else { return }
        states[key(host, environment), default: ServerPanelState()][keyPath: field] = value
    }

    func reload() async {
        guard !isBusy, let host, let servers else { return }
        activity = "Dev・Prodを確認中…"
        defer { activity = nil }
        for environment in ServerEnvironment.allCases {
            let key = key(host, environment)
            do {
                let api = try await servers.client(for: host, environment: environment == .dev ? .dev : .prod).manager
                try await refresh(api, key: key)
                append("状態を確認しました", key: key)
            } catch {
                states[key, default: ServerPanelState()].error = error.localizedDescription
                append(error.localizedDescription, key: key, isError: true)
            }
        }
    }

    private func refresh(_ api: ManagerAPI, key: Key) async throws {
        let status = try await api.status()
        guard status.environment == key.environment.rawValue.lowercased() else { throw WhubClientError.invalidResponse }
        let builds = try await api.builds()
        let commits = try await key.environment == .dev ? api.commits() : []
        var state = states[key] ?? ServerPanelState()
        state.running = status.running
        state.builds = builds
        state.commits = commits
        state.locked = status.locked
        state.error = nil
        state.checkedAt = .now
        if !builds.contains(where: { $0.id == state.selectedBuild }) { state.selectedBuild = builds.first?.id ?? "" }
        if !commits.contains(where: { $0.id == state.selectedCommit }) { state.selectedCommit = commits.first?.id ?? "" }
        states[key] = state
        if let update = status.update { append("\(update.id) · \(update.status)", key: key) }
    }

    func run(_ action: ServerAction, environment: ServerEnvironment) async {
        guard !isBusy, let host, let servers else { return }
        let key = key(host, environment)
        let state = states[key] ?? ServerPanelState()
        if action == .build && environment == .dev && state.selectedCommit.isEmpty { return }
        if action == .apply && state.selectedBuild.isEmpty { return }
        activity = "\(environment.rawValue) · \(action.rawValue)…"
        defer { activity = nil }
        var acceptedID: String?
        var submitted = false
        do {
            let api = try await servers.client(for: host, environment: environment == .dev ? .dev : .prod).manager
            let status = try await api.status()
            guard status.environment == environment.rawValue.lowercased() else { throw WhubClientError.invalidResponse }
            submitted = true
            let accepted: ManagerAPI.Update
            switch action {
            case .fetch: accepted = try await api.fetch()
            case .build: accepted = try await api.build(commit: environment == .dev ? state.selectedCommit : nil)
            case .apply: accepted = try await api.apply(buildID: state.selectedBuild)
            case .restart: accepted = try await api.restart()
            }
            acceptedID = accepted.id
            append("\(action.rawValue)受付 · \(accepted.id)", key: key)
            let result = try await wait(api, update: accepted, key: key)
            try await refresh(api, key: key)
            if result.status != "succeeded" {
                throw WhubClientError.api(status: 200, code: result.errorCode ?? result.status,
                                          message: result.error ?? result.status)
            }
            if action == .build, let id = result.targetBuild { states[key]?.selectedBuild = id }
            if action == .fetch || (action == .build && environment == .prod) { states[key]?.fetchedAt = .now }
            append("\(action.rawValue)完了", key: key)
        } catch {
            states[key, default: ServerPanelState()].error = error.localizedDescription
            if let id = acceptedID {
                append("操作ID · \(id)", key: key)
            } else if submitted, !(error is WhubClientError) {
                append("受付結果不明。再送せず、リロードで状態を確認してください。", key: key, isError: true)
            }
            if case let WhubClientError.api(_, code, message) = error {
                append("\(code)：\(message)", key: key, isError: true)
            } else {
                append(error.localizedDescription, key: key, isError: true)
            }
        }
    }

    private func wait(_ api: ManagerAPI, update initial: ManagerAPI.Update, key: Key) async throws -> ManagerAPI.Update {
        var offset: UInt64 = 0
        var previousStatus = ""
        var disconnectedAt: Date?
        while true {
            try Task.checkCancellation()
            do {
                let update = try await api.update(id: initial.id)
                let terminal = ["succeeded", "failed", "rolled_back", "recovery_failed", "launch_failed"].contains(update.status)
                if update.status != previousStatus {
                    activity = "\(key.environment.rawValue) · \(update.status)"
                    append(update.status, key: key)
                    previousStatus = update.status
                }
                // Read one chunk while running; drain the remaining log when the operation finishes.
                repeat {
                    let chunk = try await api.log(id: initial.id, offset: offset)
                    let next = chunk.nextOffset
                    if !chunk.text.isEmpty { append(chunk.text, key: key) }
                    if next == offset { break }
                    offset = next
                } while terminal
                disconnectedAt = nil
                if terminal { return update }
            } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut,
                                                 .notConnectedToInternet, .cannotFindHost].contains(error.code) {
                if disconnectedAt == nil {
                    disconnectedAt = .now
                    append("接続復旧を待っています。操作は再送しません。", key: key)
                }
                if Date().timeIntervalSince(disconnectedAt!) >= 60 { throw error }
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func append(_ message: String, key: Key, isError: Bool = false) {
        logs.append(ServerLogEntry(hostID: key.hostID, environment: key.environment, message: message, isError: isError))
    }
}
