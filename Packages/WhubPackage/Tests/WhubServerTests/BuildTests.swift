import Foundation
import Testing
@testable import WhubServer

final class BuildFixture {
    let directory: URL
    let source: URL
    let swift: URL
    let output: URL
    let log: URL
    let fm = FileManager.default

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = package.appendingPathComponent(".build/build-tests/\(UUID().uuidString)")
        source = directory.appendingPathComponent("source")
        swift = directory.appendingPathComponent("swift")
        output = directory.appendingPathComponent("output")
        log = directory.appendingPathComponent("build.log")
        try fm.createDirectory(at: source.appendingPathComponent("Packages/WhubPackage"), withIntermediateDirectories: true)
        try ".build/\n".write(to: source.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "main".write(to: source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
        try run(["init", "--bare", directory.appendingPathComponent("origin").path])
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["add", "."])
        try git(["commit", "-m", "fixture"])
        try git(["remote", "add", "origin", directory.appendingPathComponent("origin").path])
        try git(["push", "origin", "main"])
        let script = #"""
        #!/bin/sh
        fixture=$(dirname "$0")
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --package-path) shift; package="$1" ;;
            --show-bin-path) show=yes ;;
          esac
          shift
        done
        bin="$package/.build/fake-bin"
        if [ "$show" = yes ]; then printf '%s\n' "$bin"; exit 0; fi
        if [ -f "$fixture/fail-build" ]; then echo 'fixture compiler error' >&2; exit 1; fi
        if [ -f "$fixture/edit-during-build" ]; then echo 'changed' > "$package/marker"; fi
        mkdir -p "$bin"
        cp "$package/marker" "$bin/whub-server"
        chmod +x "$bin/whub-server"
        mkdir -p "$bin/Test.resources"
        echo 'resource' > "$bin/Test.resources/value"
        """#
        try script.write(to: swift, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: swift.path)
    }

    deinit { try? fm.removeItem(at: directory) }

    @discardableResult
    func git(_ arguments: [String]) throws -> String {
        try run(arguments, directory: source)
    }

    @discardableResult
    private func run(_ arguments: [String], directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BuildFixture.Git", code: Int(process.terminationStatus))
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func build(ref: String = "main") throws -> BuildArtifact {
        try ServerBuild(source: source, swift: swift.path).build(ref: ref, output: output, log: log)
    }
}

@Test func cleanBuildProducesArtifactAndResources() throws {
    let fixture = try BuildFixture()
    let expected = try fixture.git(["rev-parse", "HEAD"])
    let artifact = try fixture.build()
    #expect(artifact.commit == expected)
    #expect(UUID(uuidString: artifact.id) != nil)
    #expect(try fixture.git(["status", "--porcelain"]).isEmpty)
    #expect(try fixture.git(["rev-parse", "HEAD"]) == expected)
    #expect(try String(contentsOf: fixture.output.appendingPathComponent("whub-server"), encoding: .utf8) == "main")
    #expect(fixture.fm.isExecutableFile(atPath: fixture.output.appendingPathComponent("whub-server").path))
    #expect(try String(contentsOf: fixture.output.appendingPathComponent("Test.resources/value"), encoding: .utf8) == "resource\n")
    let saved = try JSONDecoder().decode(BuildArtifact.self, from: Data(contentsOf: fixture.output.appendingPathComponent("build.json")))
    #expect(saved == artifact)
}

@Test func fetchAndBuildArbitraryRef() throws {
    let fixture = try BuildFixture()
    try fixture.git(["checkout", "-b", "feature"])
    try "feature".write(to: fixture.source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
    try fixture.git(["add", "."])
    try fixture.git(["commit", "-m", "feature"])
    let expected = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["push", "origin", "feature"])
    try fixture.git(["checkout", "main"])
    try fixture.git(["update-ref", "-d", "refs/remotes/origin/feature"])
    let artifact = try fixture.build(ref: "refs/remotes/origin/feature")
    #expect(artifact.commit == expected)
    #expect(try String(contentsOf: fixture.output.appendingPathComponent("whub-server"), encoding: .utf8) == "feature")
}

@Test func rejectsTrackedAndUntrackedChangesWithoutDiscardingThem() throws {
    for tracked in [true, false] {
        let fixture = try BuildFixture()
        let name = tracked ? "Packages/WhubPackage/marker" : "untracked"
        let path = fixture.source.appendingPathComponent(name)
        try "local changes".write(to: path, atomically: true, encoding: .utf8)
        let head = try fixture.git(["symbolic-ref", "HEAD"])
        do { _ = try fixture.build(); Issue.record("Expected dirty_source") }
        catch let error as BuildError { #expect(error.code == "dirty_source") }
        #expect(try String(contentsOf: path, encoding: .utf8) == "local changes")
        #expect(try fixture.git(["symbolic-ref", "HEAD"]) == head)
        #expect(!fixture.fm.fileExists(atPath: fixture.output.path))
    }
}

@Test func remoteRefFetchIgnoresRestrictedDefaultRefspecAndRejectsDeletedBranch() throws {
    let fixture = try BuildFixture()
    let original = try fixture.git(["rev-parse", "HEAD"])
    try "new main".write(to: fixture.source.appendingPathComponent("Packages/WhubPackage/marker"), atomically: true, encoding: .utf8)
    try fixture.git(["add", "."])
    try fixture.git(["commit", "-m", "new main"])
    let expected = try fixture.git(["rev-parse", "HEAD"])
    try fixture.git(["push", "origin", "main"])
    try fixture.git(["update-ref", "refs/remotes/origin/main", original])
    try fixture.git(["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/elsewhere"])
    let artifact = try fixture.build(ref: "refs/remotes/origin/main")
    #expect(artifact.commit == expected)

    let deleted = try BuildFixture()
    try deleted.git(["--git-dir", deleted.directory.appendingPathComponent("origin").path,
                     "symbolic-ref", "HEAD", "refs/heads/absent"])
    try deleted.git(["push", "origin", ":main"])
    do { _ = try deleted.build(ref: "refs/remotes/origin/main"); Issue.record("Expected fetch failure") }
    catch let error as BuildError { #expect(error.code == "fetch_failed") }
    #expect(!deleted.fm.fileExists(atPath: deleted.output.path))
}

@Test func buildFailureKeepsLogAndDoesNotPublishArtifact() throws {
    let fixture = try BuildFixture()
    try Data().write(to: fixture.directory.appendingPathComponent("fail-build"))
    do { _ = try fixture.build(); Issue.record("Expected build_failed") }
    catch let error as BuildError { #expect(error.code == "build_failed") }
    #expect(!fixture.fm.fileExists(atPath: fixture.output.path))
    #expect(try String(contentsOf: fixture.log, encoding: .utf8).contains("fixture compiler error"))
}

@Test func rejectsEditsDuringBuild() throws {
    let fixture = try BuildFixture()
    try Data().write(to: fixture.directory.appendingPathComponent("edit-during-build"))
    do { _ = try fixture.build(); Issue.record("Expected dirty_source") }
    catch let error as BuildError { #expect(error.code == "dirty_source") }
    #expect(!fixture.fm.fileExists(atPath: fixture.output.path))
}

@Test func existingOutputIsPreserved() throws {
    let fixture = try BuildFixture()
    try fixture.fm.createDirectory(at: fixture.output, withIntermediateDirectories: true)
    let sentinel = fixture.output.appendingPathComponent("existing")
    try Data("keep".utf8).write(to: sentinel)
    do { _ = try fixture.build(); Issue.record("Expected output_exists") }
    catch let error as BuildError { #expect(error.code == "output_exists") }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
}

@Test func invalidRefAndMissingRefDoNotPublishArtifacts() throws {
    let fixture = try BuildFixture()
    do { _ = try fixture.build(ref: "--help"); Issue.record("Expected invalid_ref") }
    catch let error as BuildError { #expect(error.code == "invalid_ref") }
    do { _ = try fixture.build(ref: "missing-branch"); Issue.record("Expected ref_resolution_failed") }
    catch let error as BuildError { #expect(error.code == "ref_resolution_failed") }
    #expect(!fixture.fm.fileExists(atPath: fixture.output.path))
}
