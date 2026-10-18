import Foundation
import Testing
@testable import WhubServer

private let health = URL(string: "http://127.0.0.1:8080/ping")!

private func manager(_ fixture: BuildFixture,
                     verify: @escaping @Sendable (String, URL, URL) async throws -> Void = { _, _, _ in }) -> ServerManager {
    ServerManager(root: fixture.directory.appendingPathComponent("server"), restart: { _, _ in }, stop: { _, _ in },
                   verify: verify, launch: { _, _, _ in })
}

private func configuration(_ fixture: BuildFixture, _ environment: ServerEnvironment = .dev) -> ManagerConfiguration {
    ManagerConfiguration(environment: environment, source: fixture.source, swift: fixture.swift.path,
                         service: "whub-\(environment.rawValue)", healthURL: health)
}

private func operation(_ releases: ServerManager, _ fixture: BuildFixture, _ action: ServerOperation,
                       environment: ServerEnvironment = .dev, commit: String? = nil, buildID: String? = nil) async throws -> ServerUpdate {
    let queued = try releases.start(configuration: configuration(fixture, environment), ref: commit,
                                    executable: fixture.swift, operation: action, buildID: buildID)
    return try await releases.perform(id: queued.id)
}

@Test func separateFetchBuildApplyAndRestartPreserveTheSelectedArtifact() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let first = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    try fixture.git(["checkout", "main"])
    try "next".write(to: fixture.source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
    try fixture.git(["commit", "-am", "next"])
    try fixture.git(["push", "origin", "main"])
    let selected = try fixture.git(["rev-parse", "HEAD"])

    let fetched = try await operation(releases, fixture, .fetch)
    #expect(fetched.status == "succeeded")
    #expect(try releases.commits(environment: .dev).contains { $0.id == selected })
    let built = try await operation(releases, fixture, .build, commit: selected)
    let id = try #require(built.targetBuild)
    let current = releases.root.appendingPathComponent("environments/dev/current")
    #expect(built.status == "succeeded")
    #expect(built.commit == selected)
    #expect(built.activeBuild == first.targetBuild)
    #expect(current.resolvingSymlinksInPath().lastPathComponent == first.targetBuild)
    #expect(try releases.builds(environment: .dev).map(\.id) == [id])
    #expect(try releases.builds(environment: .prod).isEmpty)

    // Apply and restart must work without Git access or a usable compiler.
    try fixture.git(["remote", "set-url", "origin", fixture.directory.appendingPathComponent("missing-origin").path])
    try Data().write(to: fixture.directory.appendingPathComponent("fail-build"))
    let applied = try await operation(releases, fixture, .apply, buildID: id)
    #expect(applied.status == "succeeded")
    #expect(applied.activeBuild == id)
    #expect(applied.previousBuild == first.targetBuild)
    #expect(current.resolvingSymlinksInPath().lastPathComponent == id)
    #expect(try String(contentsOf: current.appendingPathComponent("whub-server"), encoding: .utf8) == "next")
    let restarted = try await operation(releases, fixture, .restart)
    #expect(restarted.status == "succeeded")
    #expect(restarted.activeBuild == id)
    #expect(try releases.builds(environment: .dev).map(\.id) == [id])
    #expect(releases.root.appendingPathComponent("environments/dev/previous").resolvingSymlinksInPath().lastPathComponent == first.targetBuild)
}

@Test func prodBuildPinsFetchedMainAndApplyRejectsDevArtifacts() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let main = try fixture.git(["rev-parse", "HEAD"])
    let dev = try await operation(releases, fixture, .build, commit: main)
    do {
        _ = try await operation(releases, fixture, .apply, environment: .prod, buildID: dev.targetBuild)
        Issue.record("Expected cross-environment rejection")
    } catch let error as ReleaseError { #expect(error.code == "not_found") }
    try fixture.git(["checkout", "-b", "feature"])
    try "feature".write(to: fixture.source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
    try fixture.git(["commit", "-am", "feature"])
    let prod = try await operation(releases, fixture, .build, environment: .prod)
    #expect(prod.status == "succeeded")
    #expect(prod.ref == "refs/remotes/origin/main")
    #expect(prod.commit == main)
    #expect(!fixture.fm.fileExists(atPath: releases.root.appendingPathComponent("environments/prod/current").path))
    try fixture.git(["checkout", "main"])
    try "later main".write(to: fixture.source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
    try fixture.git(["commit", "-am", "later main"])
    try fixture.git(["push", "origin", "main"])
    let applied = try await operation(releases, fixture, .apply, environment: .prod, buildID: prod.targetBuild)
    #expect(applied.status == "succeeded")
    #expect(applied.commit == main)
    #expect(applied.targetBuild == prod.targetBuild)
    #expect(try String(contentsOf: releases.root.appendingPathComponent("environments/prod/current/whub-server"), encoding: .utf8) == "main")
    do {
        _ = try await operation(releases, fixture, .build, environment: .prod, commit: main)
        Issue.record("Expected explicit Prod commit rejection")
    } catch let error as ReleaseError { #expect(error.code == "invalid_ref") }
}

@Test func separateApplyRestoresPreviousOnFailureAndRestartReportsUnknownState() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let first = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    let built = try await operation(releases, fixture, .build, commit: fixture.git(["rev-parse", "HEAD"]))
    let failing = manager(fixture) { _, _, executable in
        if executable.deletingLastPathComponent().lastPathComponent != first.targetBuild {
            throw ReleaseError("health_failed", "fixture")
        }
    }
    let applied = try await operation(failing, fixture, .apply, buildID: built.targetBuild)
    #expect(applied.status == "rolled_back")
    #expect(applied.activeBuild == first.targetBuild)
    let failedRestart = manager(fixture) { _, _, _ in throw ReleaseError("health_failed", "fixture") }
    let restarted = try await operation(failedRestart, fixture, .restart)
    #expect(restarted.status == "failed")
    #expect(restarted.errorCode == "health_failed")
    #expect(restarted.activeBuild == nil)
    #expect(releases.root.appendingPathComponent("environments/dev/current").resolvingSymlinksInPath().lastPathComponent == first.targetBuild)
}

@Test func allNewOperationsShareTheExistingLock() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let commit = try fixture.git(["rev-parse", "HEAD"])
    let queued = try releases.start(configuration: configuration(fixture), ref: nil, executable: fixture.swift, operation: .fetch)
    for action in [ServerOperation.fetch, .build, .apply, .restart] {
        do {
            _ = try releases.start(configuration: configuration(fixture), ref: action == .build ? commit : nil,
                                   executable: fixture.swift, operation: action, buildID: action == .apply ? UUID().uuidString : nil)
            Issue.record("Expected shared lock rejection")
        } catch let error as ReleaseError { #expect(error.code == "update_locked") }
    }
    #expect(try releases.status(environment: .dev, running: nil).update?.id == queued.id)
    _ = try await releases.perform(id: queued.id)
    #expect(!fixture.fm.fileExists(atPath: releases.root.appendingPathComponent("update.lock").path))
}

@Test func legacySavedRequestsWithoutOperationFieldsRemainExecutable() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let queued = try releases.start(configuration: configuration(fixture), ref: "main", executable: fixture.swift)
    for name in ["request.json", "state.json"] {
        let file = releases.root.appendingPathComponent("updates/\(queued.id)/\(name)")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object.removeValue(forKey: "operation")
        object.removeValue(forKey: "commit")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
    }
    let completed = try await releases.perform(id: queued.id)
    #expect(completed.status == "succeeded")
    #expect(completed.activeBuild == completed.targetBuild)
}

private func build(_ fixture: BuildFixture) -> ServerBuild {
    ServerBuild(source: fixture.source, swift: fixture.swift.path)
}

@Test func releasesKeepIndependentEnvironmentsAndHistory() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let prod = try await releases.release(environment: .prod, build: build(fixture), service: "whub-prod", healthURL: health)
    let dev = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    #expect(prod.status == "succeeded")
    #expect(prod.ref == "refs/remotes/origin/main")
    #expect(dev.status == "succeeded")
    #expect(prod.targetBuild != dev.targetBuild)
    for update in [prod, dev] {
        let current = releases.root.appendingPathComponent("environments/\(update.environment.rawValue)/current")
        #expect(current.resolvingSymlinksInPath().lastPathComponent == update.targetBuild)
        #expect(fixture.fm.fileExists(atPath: current.appendingPathComponent("build.json").path))
    }
    let history = try releases.history()
    #expect(history.count == 2)
    #expect(history.allSatisfy { $0.status == "succeeded" && $0.finishedAt != nil })
    #expect(try releases.history(environment: .dev).map(\.id) == [dev.id])
    #expect(try releases.history(environment: .prod).map(\.id) == [prod.id])
}

@Test func releaseBuildFailureKeepsCurrentAndRecordsError() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let first = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    try Data().write(to: fixture.directory.appendingPathComponent("fail-build"))
    let failed = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    #expect(failed.status == "failed")
    #expect(failed.error?.contains("build_failed") == true)
    #expect(failed.activeBuild == first.targetBuild)
    #expect(failed.targetBuild == nil)
    #expect(try releases.history().count == 2)
    let current = releases.root.appendingPathComponent("environments/dev/current")
    #expect(current.resolvingSymlinksInPath().lastPathComponent == first.targetBuild)
}

@Test func failedStartRestoresPreviousAndRetainsBothArtifacts() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    let first = try await releases.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    let failing = manager(fixture) { _, _, executable in
        if executable.deletingLastPathComponent().lastPathComponent != first.targetBuild {
            throw ReleaseError("health_failed", "fixture")
        }
    }
    let failed = try await failing.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    #expect(failed.status == "rolled_back")
    #expect(failed.activeBuild == first.targetBuild)
    #expect(failed.previousBuild == first.targetBuild)
    #expect(failed.targetBuild != first.targetBuild)
    #expect(fixture.fm.fileExists(atPath: releases.root.appendingPathComponent("releases/\(try #require(failed.targetBuild))/whub-server").path))
    #expect(releases.root.appendingPathComponent("environments/dev/current").resolvingSymlinksInPath().lastPathComponent == first.targetBuild)
}

@Test func failedRecoveryRecordsUnknownActiveBuild() async throws {
    let fixture = try BuildFixture()
    _ = try await manager(fixture).release(environment: .prod, build: build(fixture), service: "whub-prod", healthURL: health)
    let failing = manager(fixture) { _, _, _ in throw ReleaseError("health_failed", "fixture") }
    let failed = try await failing.release(environment: .prod, build: build(fixture), service: "whub-prod", healthURL: health)
    #expect(failed.status == "recovery_failed")
    #expect(failed.activeBuild == nil)
    #expect(failed.error?.contains("recovery:") == true)
}

@Test func failedFirstInstallRemovesCurrentAndRecordsFailure() async throws {
    let fixture = try BuildFixture()
    let failing = manager(fixture) { _, _, _ in throw ReleaseError("health_failed", "fixture") }
    let failed = try await failing.release(environment: .dev, ref: "main", build: build(fixture), service: "whub-dev", healthURL: health)
    #expect(failed.status == "failed")
    #expect(failed.previousBuild == nil)
    #expect(failed.activeBuild == nil)
    #expect(failed.targetBuild != nil)
    #expect(!fixture.fm.fileExists(atPath: failing.root.appendingPathComponent("environments/dev/current").path))
}

@Test func releasesRejectParallelUpdatesAcrossEnvironmentsAndInvalidProdRef() async throws {
    let fixture = try BuildFixture()
    let releases = manager(fixture)
    try fixture.fm.createDirectory(at: releases.root.appendingPathComponent("update.lock"), withIntermediateDirectories: true)
    for env in [ServerEnvironment.dev, .prod] {
        do {
            _ = try await releases.release(environment: env, ref: env == .dev ? "main" : nil,
                                           build: build(fixture), service: "whub-server", healthURL: health)
            Issue.record("Expected lock rejection")
        } catch let error as ReleaseError { #expect(error.code == "update_locked") }
    }
    do {
        _ = try await releases.release(environment: .prod, ref: "feature", build: build(fixture), service: "whub-prod", healthURL: health)
        Issue.record("Expected prod ref rejection")
    } catch let error as ReleaseError { #expect(error.code == "invalid_ref") }
    #expect(try releases.history().isEmpty)
}
