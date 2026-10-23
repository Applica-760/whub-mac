import Foundation

@MainActor
func waitForGitTest(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw GitTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

enum GitTestError: Error { case gitFailed, timeout }

@MainActor
struct GitTestFixture {
    let directory: URL
    let first: URL
    let second: URL
    let firstFile: URL
    let secondFile: URL

    func git(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitTestError.gitFailed }
    }

    init() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = project.appendingPathComponent("DerivedData/GitStoreTests/" + UUID().uuidString)
        first = directory.appendingPathComponent("first")
        second = directory.appendingPathComponent("second")
        firstFile = first.appendingPathComponent("first.swift")
        secondFile = second.appendingPathComponent("second.swift")
        do {
            for root in [first, second] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["init", "--quiet", root.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw GitTestError.gitFailed }
            }
            try "original\n".write(to: firstFile, atomically: true, encoding: .utf8)
            try "second\n".write(to: secondFile, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
