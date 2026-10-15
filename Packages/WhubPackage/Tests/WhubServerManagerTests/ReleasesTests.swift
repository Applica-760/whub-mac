import Foundation
import Testing
@testable import WhubServerManager

private let health = URL(string: "http://127.0.0.1:8080/ping")!

private func manager(_ fixture: BuildFixture,
                     verify: @escaping @Sendable (String, URL, URL) async throws -> Void = { _, _, _ in }) -> ServerReleases {
    ServerReleases(root: fixture.directory.appendingPathComponent("server"), restart: { _, _ in }, stop: { _, _ in }, verify: verify)
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
