import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import WhubServer

private final class FilesFixture: Sendable {
    let directory: URL
    let first: URL
    let second: URL
    let app: Application<RouterResponder<BasicRequestContext>>

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = package.appendingPathComponent(".build/files-tests/\(UUID().uuidString)").resolvingSymlinksInPath()
        first = directory.appendingPathComponent("first + 日本語")
        second = directory.appendingPathComponent("second")
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let configuration = ManagerConfiguration(environment: .dev, source: directory, swift: "/usr/bin/swift",
                                                 service: "fixture", healthURL: URL(string: "http://127.0.0.1/ping")!)
        let manager = ManagerAPI(releases: ServerReleases(root: directory.appendingPathComponent("manager")),
                                 configuration: configuration, token: String(repeating: "x", count: 32),
                                 executable: directory, running: nil)
        app = Application(router: makeRouter(files: FilesAPI(), manager: manager))
    }

    func uri(_ endpoint: String, root: URL, path: String? = nil) -> String {
        var components = URLComponents()
        components.path = "/files/\(endpoint)"
        components.queryItems = [URLQueryItem(name: "root", value: root.path)]
        if let path { components.queryItems!.append(URLQueryItem(name: "path", value: path)) }
        return components.string!.replacingOccurrences(of: "+", with: "%2B")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@Test func filesRequestsSelectTheirOwnRootAndDecodeNames() async throws {
    let fixture = try FilesFixture()
    let name = "hello + 日本語.txt"
    for (root, text) in [(fixture.first, "first"), (fixture.second, "second")] {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try await fixture.app.test(.router) { client in
        for (root, text) in [(fixture.first, "first"), (fixture.second, "second"), (fixture.first, "first")] {
            let listing = try await client.execute(uri: fixture.uri("list", root: root), method: .get)
            #expect(listing.status == .ok)
            let entries = try JSONDecoder().decode([[String: String]].self, from: Data(listing.body.readableBytesView))
            #expect(entries == [["name": name, "kind": "file"]])
            let read = try await client.execute(uri: fixture.uri("read", root: root, path: name), method: .get)
            #expect(read.status == .ok)
            #expect(try JSONDecoder().decode([String: String].self, from: Data(read.body.readableBytesView)) == ["text": text])
        }
        let ping = try await client.execute(uri: "/ping", method: .get)
        #expect(ping.status == .ok)
        #expect(String(buffer: ping.body) == "pong")
    }
}

@Test func filesRejectInvalidQueriesAndTraversal() async throws {
    let fixture = try FilesFixture()
    let valid = fixture.uri("list", root: fixture.first)
    try await fixture.app.test(.router) { client in
        for uri in ["/files/list", "/files/list?path=", "/files/list?root=", "/files/list?root=relative",
                    valid + "&root=/", valid + "&%72oot=/", valid + "&unknown=x", valid + "&path=&path=",
                    valid + "&path=%", valid + "&path=/etc", valid + "&path=..%2Fsecond",
                    valid + "&path=%00", valid + "&path", "/files/list?root=/a/../b",
                    fixture.uri("read", root: fixture.first)] {
            let response = try await client.execute(uri: uri, method: .get)
            #expect(response.status == .badRequest, "\(uri)")
        }
    }
}

@Test func filesKeepSymlinkAndTextRestrictions() async throws {
    let fixture = try FilesFixture()
    let fm = FileManager.default
    try "outside".write(to: fixture.second.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: fixture.first.appendingPathComponent("link"), withDestinationURL: fixture.second)
    try Data([0]).write(to: fixture.first.appendingPathComponent("binary"))
    try Data([0xFF]).write(to: fixture.first.appendingPathComponent("invalid-utf8"))
    try Data(repeating: 65, count: 1_048_577).write(to: fixture.first.appendingPathComponent("large"))
    try await fixture.app.test(.router) { client in
        for (endpoint, path, code) in [("list", "link", "symlink_forbidden"), ("read", "link/secret", "symlink_forbidden"),
                                       ("read", "binary", "binary_file"), ("read", "invalid-utf8", "invalid_utf8"),
                                       ("read", "large", "text_too_large")] {
            let response = try await client.execute(uri: fixture.uri(endpoint, root: fixture.first, path: path), method: .get)
            #expect(response.status == (code == "symlink_forbidden" ? .forbidden : .unprocessableContent))
            let body = try JSONDecoder().decode([String: [String: String]].self, from: Data(response.body.readableBytesView))
            #expect(body["error"]?["code"] == code)
        }
        let rootLink = try await client.execute(uri: fixture.uri("list", root: fixture.first.appendingPathComponent("link")), method: .get)
        #expect(rootLink.status == .forbidden)
    }
}


@Test func filesWritePreservesBytesPermissionsAndRejectsStaleBase() async throws {
    let fixture = try FilesFixture()
    let file = fixture.first.appendingPathComponent("日本語 + file")
    let original = "\u{FEFF}before\r\n"
    let saved = "\u{FEFF}after\r\n"
    try Data(original.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: file.path)
    let body = try JSONEncoder().encode(["expectedText": original, "text": saved])
    try await fixture.app.test(.router) { client in
        let uri = fixture.uri("write", root: fixture.first, path: file.lastPathComponent)
        let response = try await client.execute(uri: uri, method: .put, headers: [.contentType: "application/json"],
                                               body: .init(bytes: body))
        #expect(response.status == .ok)
        #expect(try Data(contentsOf: file) == Data(saved.utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o750)
        let read = try await client.execute(uri: fixture.uri("read", root: fixture.first, path: file.lastPathComponent), method: .get)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(read.body.readableBytesView))["text"] == saved)
        let conflict = try await client.execute(uri: uri, method: .put, headers: [.contentType: "application/json"],
                                               body: .init(bytes: body))
        #expect(conflict.status == .conflict)
        #expect(try Data(contentsOf: file) == Data(saved.utf8))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.first.path) == [file.lastPathComponent])
}

@Test func filesWriteChecksBytesRatherThanUnicodeEquivalenceAndSerializesSaves() async throws {
    let fixture = try FilesFixture()
    let file = fixture.first.appendingPathComponent("file")
    let service = try FilesService(root: fixture.first.path)
    try Data("e\u{301}".utf8).write(to: file)
    #expect(throws: FilesError.conflict) { try service.writeText(path: "file", expectedText: "é", text: "replacement") }
    try Data("base".utf8).write(to: file)
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for text in ["one", "two"] {
            group.addTask {
                do {
                    _ = try service.writeText(path: "file", expectedText: "base", text: text)
                    return true
                } catch { return false }
            }
        }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(results.filter { $0 }.count == 1)
    #expect(["one", "two"].contains(try service.readText(path: "file")))
}

@Test func filesWriteRefusesUnsafeUnsupportedAndUnwritableTargetsWithoutChangingFiles() async throws {
    let fixture = try FilesFixture()
    let fm = FileManager.default
    let file = fixture.first.appendingPathComponent("file")
    try Data("base".utf8).write(to: file)
    try fm.createSymbolicLink(at: fixture.first.appendingPathComponent("link"), withDestinationURL: fixture.second)
    try fm.createSymbolicLink(at: fixture.first.appendingPathComponent("file-link"), withDestinationURL: file)
    try Data("outside".utf8).write(to: fixture.second.appendingPathComponent("file"))
    let service = try FilesService(root: fixture.first.path)
    for path in ["", ".", "file/", "../second/file", "/file", "file\0", "link/file", "file-link", "missing"] {
        #expect(throws: (any Error).self) { try service.writeText(path: path, expectedText: "base", text: "changed") }
    }
    #expect(throws: FilesError.binaryFile) { try service.writeText(path: "file", expectedText: "base", text: "bad\0") }
    #expect(throws: FilesError.textTooLarge) {
        try service.writeText(path: "file", expectedText: "base", text: String(repeating: "a", count: 1_048_577))
    }
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try service.writeText(path: "file", expectedText: "base", text: "changed") }
    #expect(try Data(contentsOf: file) == Data("base".utf8))
    #expect(try Data(contentsOf: fixture.second.appendingPathComponent("file")) == Data("outside".utf8))
    #expect(try fm.contentsOfDirectory(atPath: fixture.first.path).allSatisfy { !$0.hasPrefix(".whub-save-") })
}

@Test func filesWriteValidatesRequestAndSupportsEscapedOneMiBText() async throws {
    let fixture = try FilesFixture()
    let file = fixture.first.appendingPathComponent("file")
    let text = String(repeating: "\t", count: 1_048_576)
    try Data(text.utf8).write(to: file)
    try await fixture.app.test(.router) { client in
        let uri = fixture.uri("write", root: fixture.first, path: "file")
        for body in ["{}", "{", #"{"expectedText":null,"text":"x"}"#] {
            let response = try await client.execute(uri: uri, method: .put, headers: [.contentType: "application/json"],
                                                   body: .init(string: body))
            #expect(response.status == .badRequest)
        }
        let wrongType = try await client.execute(uri: uri, method: .put, body: .init(string: "{}"))
        #expect(wrongType.status == .badRequest)
        let body = try JSONEncoder().encode(["expectedText": text, "text": text])
        let response = try await client.execute(uri: uri, method: .put, headers: [.contentType: "application/json"],
                                               body: .init(bytes: body))
        #expect(response.status == .ok)
        #expect(try Data(contentsOf: file) == Data(text.utf8))
    }
}
