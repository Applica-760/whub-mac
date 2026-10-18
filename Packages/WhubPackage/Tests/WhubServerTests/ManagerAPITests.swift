import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import WhubServer

private func managerAPI(_ fixture: BuildFixture, environment: ServerEnvironment = .dev, executable: URL? = nil,
                        launch: @escaping @Sendable (URL, String, URL) throws -> Void = { _, _, _ in }) -> ManagerAPI {
    let releases = ServerManager(root: fixture.directory.appendingPathComponent("server"), restart: { _, _ in },
                                  stop: { _, _ in }, verify: { _, _, _ in }, launch: launch)
    let configuration = ManagerConfiguration(environment: environment, source: fixture.source, swift: fixture.swift.path,
                                             service: "whub-\(environment.rawValue)", healthURL: URL(string: "http://127.0.0.1:8080/ping")!)
    return ManagerAPI(manager: releases, configuration: configuration,
                      executable: executable ?? fixture.swift, running: BuildArtifact(id: "running-build", commit: "running-commit"))
}

private func updateDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}

@Test func managerNewRoutesExposeSeparateOperationsArtifactsAndCommitSnapshot() async throws {
    let fixture = try BuildFixture()
    let api = managerAPI(fixture)
    let commit = try fixture.git(["rev-parse", "HEAD"])
    let app = Application(router: makeRouter(files: FilesAPI(), manager: api))
    let headers: HTTPFields = [.contentType: "application/json"]
    try await app.test(.router) { client in
        var buildID = ""
        for action in [ServerOperation.fetch, .build, .apply, .restart] {
            let path = action == .build ? "builds" : action.rawValue
            let body: String
            switch action {
            case .build: body = "{\"commit\":\"\(commit)\"}"
            case .apply: body = "{\"buildID\":\"\(buildID)\"}"
            default: body = "{}"
            }
            let response = try await client.execute(uri: "/manager/\(path)", method: .post, headers: headers,
                                                    body: .init(string: body))
            #expect(response.status == .accepted)
            let queued = try updateDecoder().decode(ServerUpdate.self, from: Data(response.body.readableBytesView))
            #expect(queued.operation == action)
            #expect(response.headers[.location] == "/manager/updates/\(queued.id)")
            let completed = try await api.manager.perform(id: queued.id)
            #expect(completed.status == "succeeded")
            if action == .fetch {
                let commits = try await client.execute(uri: "/manager/commits", method: .get, headers: headers)
                #expect(commits.status == .ok)
                let values = try updateDecoder().decode([ServerCommit].self, from: Data(commits.body.readableBytesView))
                #expect(values.map(\.id) == [commit])
                #expect(values[0].committedAt.timeIntervalSince1970 > 0)
            }
            if action == .build {
                buildID = try #require(completed.targetBuild)
                #expect(!FileManager.default.fileExists(atPath: api.manager.root.appendingPathComponent("environments/dev/current").path))
                let builds = try await client.execute(uri: "/manager/builds", method: .get, headers: headers)
                #expect(builds.status == .ok)
                let values = try updateDecoder().decode([BuildArtifact].self, from: Data(builds.body.readableBytesView))
                #expect(values.map(\.id) == [buildID])
            }
            if action == .apply || action == .restart { #expect(completed.activeBuild == buildID) }
            let detail = try await client.execute(uri: "/manager/updates/\(queued.id)", method: .get, headers: headers)
            #expect(try updateDecoder().decode(ServerUpdate.self, from: Data(detail.body.readableBytesView)).status == "succeeded")
            let log = try await client.execute(uri: "/manager/updates/\(queued.id)/log?offset=0", method: .get, headers: headers)
            #expect(log.status == .ok)
        }
    }
}

@Test func managerNewRoutesRejectWrongFieldsAndProdCommitSelection() async throws {
    let fixture = try BuildFixture()
    let headers: HTTPFields = [.contentType: "application/json"]
    let dev = managerAPI(fixture)
    try await Application(router: makeRouter(files: FilesAPI(), manager: dev)).test(.router) { client in
        for (path, body) in [
            ("builds", "{}"), ("builds", #"{"commit":"main"}"#), ("builds", #"{"commit":null}"#),
            ("builds", #"{"ref":"main"}"#), ("builds", #"{"commit":42}"#),
            ("apply", "{}"), ("apply", #"{"buildID":"../outside"}"#),
            ("fetch", #"{"commit":"main"}"#), ("restart", #"{"service":"other"}"#),
            ("fetch", "[]"), ("fetch", String(repeating: "x", count: 4097)),
        ] {
            let response = try await client.execute(uri: "/manager/\(path)", method: .post, headers: headers,
                                                    body: .init(string: body))
            #expect(response.status == .badRequest)
        }
        let restart = try await client.execute(uri: "/manager/restart", method: .post, headers: headers, body: .init(string: "{}"))
        #expect(restart.status == .notFound)
        for path in ["fetch", "builds", "apply", "restart"] {
            let response = try await client.execute(uri: "/manager/\(path)?extra=1", method: .post, headers: headers,
                                                    body: .init(string: "{}"))
            #expect(response.status == .badRequest)
        }
    }
    let prod = managerAPI(fixture, environment: .prod)
    try await Application(router: makeRouter(files: FilesAPI(), manager: prod)).test(.router) { client in
        for path in ["fetch", "builds"] {
            let response = try await client.execute(uri: "/manager/\(path)", method: .post, headers: headers,
                                                    body: .init(string: #"{"commit":"main"}"#))
            #expect(response.status == .badRequest)
        }
        let commits = try await client.execute(uri: "/manager/commits", method: .get, headers: headers)
        #expect(commits.status == .badRequest)
        let response = try await client.execute(uri: "/manager/builds", method: .post, headers: headers, body: .init(string: "{}"))
        #expect(response.status == .accepted)
        let queued = try updateDecoder().decode(ServerUpdate.self, from: Data(response.body.readableBytesView))
        #expect(try await prod.manager.perform(id: queued.id).status == "succeeded")
    }
}

@Test func managerRejectsChangedArtifactMetadataBeforeApply() async throws {
    let fixture = try BuildFixture()
    let api = managerAPI(fixture)
    let commit = try fixture.git(["rev-parse", "HEAD"])
    let queued = try api.manager.start(configuration: api.configuration, ref: commit, executable: fixture.swift, operation: .build)
    let built = try await api.manager.perform(id: queued.id)
    let id = try #require(built.targetBuild)
    let metadata = api.manager.root.appendingPathComponent("releases/\(id)/build.json")
    try JSONEncoder().encode(BuildArtifact(id: id, commit: "changed")).write(to: metadata, options: .atomic)
    try await Application(router: makeRouter(files: FilesAPI(), manager: api)).test(.router) { client in
        let response = try await client.execute(uri: "/manager/apply", method: .post,
            headers: [.contentType: "application/json"],
            body: .init(string: "{\"buildID\":\"\(id)\"}"))
        #expect(response.status == .conflict)
        #expect(!FileManager.default.fileExists(atPath: api.manager.root.appendingPathComponent("update.lock").path))
    }
}

@Test func newFetchAndBuildRunInCopiedWorkerWithoutHTTPConfiguration() throws {
    let fixture = try BuildFixture()
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = package.appendingPathComponent(".build/debug/whub-server")
    let api = managerAPI(fixture, executable: executable) { root, id, runner in
        let process = Process()
        process.executableURL = runner
        process.arguments = ["update", root.path, id]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    let commit = try fixture.git(["rev-parse", "HEAD"])
    for action in [ServerOperation.fetch, .build] {
        let queued = try api.manager.start(configuration: api.configuration, ref: action == .build ? commit : nil,
                                           executable: executable, operation: action)
        #expect(try api.manager.readUpdate(id: queued.id).status == "succeeded")
    }
    #expect(try api.manager.builds(environment: .dev).count == 1)
    #expect(!fixture.fm.fileExists(atPath: api.manager.root.appendingPathComponent("environments/dev/current").path))
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
    let app = Application(router: makeRouter(files: FilesAPI(), manager: api))
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(response.status == .accepted)
        let queued = try updateDecoder().decode(ServerUpdate.self, from: Data(response.body.readableBytesView))
        #expect(queued.status == "queued")
        #expect(response.headers[.location] == "/manager/updates/\(queued.id)")
        let conflict = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(conflict.status == .conflict)
        let completed = try await api.manager.perform(id: queued.id)
        #expect(completed.id == queued.id)
        #expect(completed.status == "succeeded")
        let detail = try await client.execute(uri: "/manager/updates/\(queued.id)", method: .get)
        #expect(try updateDecoder().decode(ServerUpdate.self, from: Data(detail.body.readableBytesView)).status == "succeeded")
        let history = try await client.execute(uri: "/manager/updates", method: .get)
        #expect(try updateDecoder().decode([ServerUpdate].self, from: Data(history.body.readableBytesView)).count == 1)
        let log = try await client.execute(uri: "/manager/updates/\(queued.id)/log", method: .get)
        let chunk = try updateDecoder().decode(UpdateLog.self, from: Data(log.body.readableBytesView))
        #expect(chunk.text.contains("build"))
        #expect(chunk.nextOffset > 0)
        let end = try await client.execute(uri: "/manager/updates/\(queued.id)/log?offset=\(chunk.nextOffset)", method: .get)
        #expect(try updateDecoder().decode(UpdateLog.self, from: Data(end.body.readableBytesView)).text.isEmpty)
        let status = try await client.execute(uri: "/manager/status", method: .get)
        let state = try updateDecoder().decode(ManagerStatus.self, from: Data(status.body.readableBytesView))
        #expect(state.running?.id == "running-build")
        #expect(state.current == completed.targetBuild)
        #expect(!state.locked)
        do { _ = try await api.manager.perform(id: queued.id); Issue.record("Expected duplicate worker rejection") }
        catch let error as ReleaseError { #expect(error.code == "update_locked") }
    }
}

@Test func managerRejectsUnsafeInputAndSeparatesEnvironments() async throws {
    let fixture = try BuildFixture()
    let dev = managerAPI(fixture)
    let queued = try dev.manager.start(configuration: dev.configuration, ref: "main", executable: dev.executable)
    let prod = managerAPI(fixture, environment: .prod)
    let app = Application(router: makeRouter(files: FilesAPI(), manager: prod))
    try await app.test(.router) { client in
        for body in [#"{"ref":"feature"}"#, #"{"service":"other"}"#, #"{"ref":null}"#, "[]", String(repeating: "x", count: 4097)] {
            let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                    headers: [.contentType: "application/json"],
                                                    body: .init(string: body))
            #expect(response.status == .badRequest)
        }
        let hidden = try await client.execute(uri: "/manager/updates/\(queued.id)", method: .get)
        #expect(hidden.status == .notFound)
        let history = try await client.execute(uri: "/manager/updates", method: .get)
        #expect(try updateDecoder().decode([ServerUpdate].self, from: Data(history.body.readableBytesView)).isEmpty)
        let invalid = try await client.execute(uri: "/manager/updates/not-a-uuid/log", method: .get)
        #expect(invalid.status == .badRequest)
    }
}

@Test func managerLaunchFailureRetainsReservationForManualInspection() async throws {
    let fixture = try BuildFixture()
    let api = managerAPI(fixture) { _, _, _ in throw ReleaseError("launch_failed", "fixture") }
    let app = Application(router: makeRouter(files: FilesAPI(), manager: api))
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/manager/updates", method: .post,
                                                headers: [.contentType: "application/json"],
                                                body: .init(string: #"{"ref":"main"}"#))
        #expect(response.status == .serviceUnavailable)
        let history = try api.manager.history()
        #expect(history.count == 1)
        #expect(history.first?.status == "launch_failed")
        #expect(FileManager.default.fileExists(atPath: api.manager.root.appendingPathComponent("update.lock").path))
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
    let queued = try api.manager.start(configuration: api.configuration, ref: "main", executable: executable)
    let completed = try api.manager.readUpdate(id: queued.id)
    #expect(completed.status == "failed")
    #expect(completed.errorCode == "build_failed")
    #expect(!FileManager.default.fileExists(atPath: api.manager.root.appendingPathComponent("update.lock").path))
}

@Test func managerConfigurationRequiresCompleteAndValidSettings() throws {
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI([:]) }
    var configuration = ["WHUB_SERVER_ENVIRONMENT": "dev", "WHUB_MANAGER_ROOT": "/manager", "WHUB_MANAGER_SOURCE": "/source",
                         "WHUB_MANAGER_SWIFT": "/usr/bin/swift", "WHUB_MANAGER_SERVICE": "whub-dev.service",
                         "WHUB_MANAGER_HEALTH_URL": "http://127.0.0.1:8080/ping"]
    #expect(try WhubServer.managerAPI(configuration).configuration.environment == .dev)
    configuration["WHUB_MANAGER_SERVICE"] = "--bad"
    #expect(throws: ReleaseError.self) { try WhubServer.managerAPI(configuration) }
}
