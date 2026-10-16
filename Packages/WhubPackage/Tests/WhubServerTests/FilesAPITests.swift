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
