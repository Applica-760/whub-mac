import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import WhubServer

private let managerToken = "test-manager-token-at-least-32-characters"

private func managerAPI(_ fixture: BuildFixture, environment: ServerEnvironment = .dev, executable: URL? = nil,
                        launch: @escaping @Sendable (URL, String, URL) throws -> Void = { _, _, _ in }) -> ManagerAPI {
    let releases = ServerReleases(root: fixture.directory.appendingPathComponent("server"), restart: { _, _ in },
                                  stop: { _, _ in }, verify: { _, _, _ in }, launch: launch)
    let configuration = ManagerConfiguration(environment: environment, source: fixture.source, swift: fixture.swift.path,
                                             service: "whub-\(environment.rawValue)", healthURL: URL(string: "http://127.0.0.1:8080/ping")!)
    return ManagerAPI(releases: releases, configuration: configuration, token: managerToken,
                      executable: executable ?? fixture.swift, running: BuildArtifact(id: "running-build", commit: "running-commit"))
}

private func updateDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}

@Test func managerRoutesRequireAuthenticationBeforeReadingRequests() async throws {
    let fixture = try BuildFixture()
    let api = managerAPI(fixture)
    let app = Application(router: makeRouter(files: FilesAPI(service: try FilesService(root: fixture.source.path)), manager: api))
    try await app.test(.router) { client in
        let id = UUID().uuidString
        for uri in ["/manager/status", "/manager/updates", "/manager/updates/\(id)", "/manager/updates/\(id)/log"] {
            let response = try await client.execute(uri: uri, method: .get)
            #expect(response.status == .unauthorized)
            #expect(response.headers[.wwwAuthenticate] == "Bearer")
        }
        let response = try await client.execute(uri: "/manager/updates", method: .post)
        #expect(response.status == .unauthorized)
        let wrong = try await client.execute(uri: "/manager/status", method: .get, headers: [.authorization: "Bearer wrong"])
        #expect(wrong.status == .unauthorized)
        #expect(try api.releases.history().isEmpty)
    }
}

@Test func managerAcceptsPersistedUpdateAndExposesResultHistoryAndLogs() async throws {
    let fixture = try BuildFixture()
    let executableLink = fixture.directory.appendingPathComponent("executable-link")
    try FileManager.default.createSymbolicLink(at: executableLink, withDestinationURL: fixture.swift)
    let api = managerAPI(fixture, executable: executableLink) { root, id, runner in
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("updates/\(id)/request.json").path))
        #expect(FileManager.default.isExecutableFile(atPath: runner.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: runner.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    }
    let app = Application(router: makeRouter(files: FilesAPI(service: try FilesService(root: fixture.source.path)), manager: api))
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.authorization: "Bearer \(managerToken)", .contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(response.status == .accepted)
        let queued = try updateDecoder().decode(ServerUpdate.self, from: Data(response.body.readableBytesView))
        #expect(queued.status == "queued")
        let savedRequest = try String(contentsOf: api.releases.root.appendingPathComponent("updates/\(queued.id)/request.json"), encoding: .utf8)
        #expect(!savedRequest.contains(managerToken))
        #expect(response.headers[.location] == "/manager/updates/\(queued.id)")
        let conflict = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.authorization: "Bearer \(managerToken)", .contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(conflict.status == .conflict)
        let completed = try await api.releases.perform(id: queued.id)
        #expect(completed.id == queued.id)
        #expect(completed.status == "succeeded")
        let detail = try await client.execute(uri: "/manager/updates/\(queued.id)", method: .get,
                                              headers: [.authorization: "Bearer \(managerToken)"])
        #expect(try updateDecoder().decode(ServerUpdate.self, from: Data(detail.body.readableBytesView)).status == "succeeded")
        let history = try await client.execute(uri: "/manager/updates", method: .get, headers: [.authorization: "Bearer \(managerToken)"])
        #expect(try updateDecoder().decode([ServerUpdate].self, from: Data(history.body.readableBytesView)).count == 1)
        let log = try await client.execute(uri: "/manager/updates/\(queued.id)/log", method: .get,
                                           headers: [.authorization: "Bearer \(managerToken)"])
        let chunk = try updateDecoder().decode(UpdateLog.self, from: Data(log.body.readableBytesView))
        #expect(chunk.text.contains("build"))
        #expect(chunk.nextOffset > 0)
        let end = try await client.execute(uri: "/manager/updates/\(queued.id)/log?offset=\(chunk.nextOffset)", method: .get,
                                           headers: [.authorization: "Bearer \(managerToken)"])
        #expect(try updateDecoder().decode(UpdateLog.self, from: Data(end.body.readableBytesView)).text.isEmpty)
        let status = try await client.execute(uri: "/manager/status", method: .get, headers: [.authorization: "Bearer \(managerToken)"])
        let state = try updateDecoder().decode(ManagerStatus.self, from: Data(status.body.readableBytesView))
        #expect(state.running?.id == "running-build")
        #expect(state.current == completed.targetBuild)
        #expect(!state.locked)
        do { _ = try await api.releases.perform(id: queued.id); Issue.record("Expected duplicate worker rejection") }
        catch let error as ReleaseError { #expect(error.code == "update_locked") }
    }
}

@Test func managerRejectsUnsafeInputAndSeparatesEnvironments() async throws {
    let fixture = try BuildFixture()
    let dev = managerAPI(fixture)
    let queued = try dev.releases.start(configuration: dev.configuration, ref: "main", executable: dev.executable)
    let prod = managerAPI(fixture, environment: .prod)
    let app = Application(router: makeRouter(files: FilesAPI(service: try FilesService(root: fixture.source.path)), manager: prod))
    try await app.test(.router) { client in
        for body in [#"{"ref":"feature"}"#, #"{"service":"other"}"#, #"{"ref":null}"#, "[]", String(repeating: "x", count: 4097)] {
            let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                    headers: [.authorization: "Bearer \(managerToken)", .contentType: "application/json"],
                                                    body: .init(string: body))
            #expect(response.status == .badRequest)
        }
        let hidden = try await client.execute(uri: "/manager/updates/\(queued.id)", method: .get,
                                              headers: [.authorization: "Bearer \(managerToken)"])
        #expect(hidden.status == .notFound)
        let history = try await client.execute(uri: "/manager/updates", method: .get, headers: [.authorization: "Bearer \(managerToken)"])
        #expect(try updateDecoder().decode([ServerUpdate].self, from: Data(history.body.readableBytesView)).isEmpty)
        let invalid = try await client.execute(uri: "/manager/updates/not-a-uuid/log", method: .get,
                                               headers: [.authorization: "Bearer \(managerToken)"])
        #expect(invalid.status == .badRequest)
    }
}

@Test func managerLaunchFailureRetainsReservationForManualInspection() async throws {
    let fixture = try BuildFixture()
    let api = managerAPI(fixture) { _, _, _ in throw ReleaseError("launch_failed", "fixture") }
    let app = Application(router: makeRouter(files: FilesAPI(service: try FilesService(root: fixture.source.path)), manager: api))
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.authorization: "Bearer \(managerToken)", .contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(response.status == .serviceUnavailable)
        let history = try api.releases.history()
        #expect(history.count == 1)
        #expect(history.first?.status == "launch_failed")
        #expect(FileManager.default.fileExists(atPath: api.releases.root.appendingPathComponent("update.lock").path))
    }
}

@Test func updateModeRunsSavedRequestInSeparateProcessWithoutHTTPConfiguration() async throws {
    let fixture = try BuildFixture()
    try Data().write(to: fixture.directory.appendingPathComponent("fail-build"))
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = package.appendingPathComponent(".build/debug/whub-server")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let api = managerAPI(fixture, executable: executable) { root, id, runner in
        let process = Process()
        process.executableURL = runner
        process.arguments = ["update", root.path, id]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
    }
    let queued = try api.releases.start(configuration: api.configuration, ref: "main", executable: executable)
    let completed = try api.releases.readUpdate(id: queued.id)
    #expect(completed.status == "failed")
    #expect(completed.errorCode == "build_failed")
    #expect(!FileManager.default.fileExists(atPath: api.releases.root.appendingPathComponent("update.lock").path))
}

@Test func managerConfigurationRequiresCompleteAndValidSettings() throws {
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI([:]) }
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI(["WHUB_MANAGER_TOKEN": "short"]) }
    var configuration = ["WHUB_SERVER_ENVIRONMENT": "dev", "WHUB_MANAGER_ROOT": "/manager", "WHUB_MANAGER_SOURCE": "/source",
                         "WHUB_MANAGER_SWIFT": "/usr/bin/swift", "WHUB_MANAGER_SERVICE": "whub-dev.service",
                         "WHUB_MANAGER_HEALTH_URL": "http://127.0.0.1:8080/ping", "WHUB_MANAGER_TOKEN": managerToken]
    #expect(try WhubServer.managerAPI(configuration).configuration.environment == .dev)
    configuration["WHUB_MANAGER_TOKEN"] = "short"
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI(configuration) }
    configuration["WHUB_MANAGER_TOKEN"] = managerToken
    configuration["WHUB_MANAGER_SERVICE"] = "--bad"
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI(configuration) }
}
