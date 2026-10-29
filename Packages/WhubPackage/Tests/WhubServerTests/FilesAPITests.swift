import Foundation
import Hummingbird
import WhubAgent
import HummingbirdTesting
import Testing
import struct WhubClient.WhubClient
import enum WhubClient.WhubClientError
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import WhubServer

private final class FilesFixture: Sendable {
    let directory: URL
    let first: URL
    let second: URL
    let app: Application<RouterResponder<BasicRequestContext>>

    init() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = package.appendingPathComponent(".build/files-tests/\(UUID().uuidString)").resolvingSymlinksInPath()
        first = directory.appendingPathComponent("first + 日本語")
        second = directory.appendingPathComponent("second")
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let configuration = ManagerConfiguration(environment: .dev, source: directory, swift: "/usr/bin/swift",
                                                 service: "fixture", healthURL: URL(string: "http://127.0.0.1/ping")!)
        let manager = ManagerAPI(manager: ServerManager(root: directory.appendingPathComponent("manager")),
                                 configuration: configuration,
                                 executable: directory, running: nil)
        app = Application(router: makeRouter(files: FilesAPI(), manager: manager, agent: AgentAPI(runtime: await AgentRuntime())))
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

@Test func filesReadImageReturnsBytesAndErrors() async throws {
    let fixture = try await FilesFixture()
    let bytes = Data([0, 255, 1, 128])
    try bytes.write(to: fixture.first.appendingPathComponent("image + 日本語.png"))
    try Data(repeating: 0, count: 8 * 1_048_576 + 1).write(to: fixture.first.appendingPathComponent("large"))
    try FileManager.default.createSymbolicLink(atPath: fixture.first.appendingPathComponent("link").path,
                                               withDestinationPath: "image + 日本語.png")
    try await fixture.app.test(.router) { client in
        let uri = fixture.uri("read-image", root: fixture.first, path: "image + 日本語.png")
        let response = try await client.execute(uri: uri, method: .get)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/octet-stream")
        #expect(Data(response.body.readableBytesView) == bytes)

        for (path, status, code) in [("large", HTTPResponse.Status.unprocessableContent, "image_too_large"),
                                     ("link", .forbidden, "symlink_forbidden"),
                                     ("missing", .notFound, "not_found"),
                                     ("", .badRequest, "invalid_path")] {
            let result = try await client.execute(uri: fixture.uri("read-image", root: fixture.first, path: path), method: .get)
            #expect(result.status == status)
            let error = try JSONDecoder().decode([String: [String: String]].self, from: Data(result.body.readableBytesView))
            #expect(error["error"]?["code"] == code)
        }
    }
}

@Test func filesRequestsSelectTheirOwnRootAndDecodeNames() async throws {
    let fixture = try await FilesFixture()
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
    let fixture = try await FilesFixture()
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

@Test func filesCreateAndRenameWithoutOverwriting() async throws {
    let fixture = try await FilesFixture()
    try await fixture.app.test(.router) { client in
        let folder = fixture.uri("create-directory", root: fixture.first, path: "folder")
        let createdFolder = try await client.execute(uri: folder, method: .post)
        #expect(createdFolder.status == .noContent)
        let file = fixture.uri("create-file", root: fixture.first, path: "folder/one.txt")
        let createdFile = try await client.execute(uri: file, method: .post)
        #expect(createdFile.status == .noContent)
        let duplicate = try await client.execute(uri: file, method: .post)
        #expect(duplicate.status == .conflict)
        let rename = fixture.uri("rename", root: fixture.first, path: "folder/one.txt")
        let headers: HTTPFields = [.contentType: "application/json"]
        let renamed = try await client.execute(uri: rename, method: .post, headers: headers,
                                               body: .init(string: #"{"name":"two.txt"}"#))
        #expect(renamed.status == .noContent)
        #expect(FileManager.default.fileExists(atPath: fixture.first.appendingPathComponent("folder/two.txt").path))
        _ = try await client.execute(uri: file, method: .post)
        let collision = try await client.execute(uri: rename, method: .post, headers: headers,
                                                 body: .init(string: #"{"name":"two.txt"}"#))
        #expect(collision.status == .conflict)
        let invalidTrash = try await client.execute(uri: fixture.uri("trash", root: fixture.first, path: "../second"), method: .post)
        #expect(invalidTrash.status == .badRequest)
        let invalidRename = try await client.execute(uri: rename, method: .post, headers: headers,
                                                     body: .init(string: #"{"name":"../escape"}"#))
        #expect(invalidRename.status == .badRequest)
    }
}

@Test func filesClientCreatesAndRenames() async throws {
    let fixture = try await FilesFixture()
    try await fixture.app.test(.live) { transport in
        let port = try #require(transport.port)
        let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
        let root = fixture.first.path
        try await client.files.createDirectory(root: root, path: "folder")
        try await client.files.createFile(root: root, path: "folder/a + 日本語.txt")
        try await client.files.rename(root: root, path: "folder/a + 日本語.txt", name: "renamed.txt")
        #expect(FileManager.default.fileExists(atPath: fixture.first.appendingPathComponent("folder/renamed.txt").path))
        await #expect(throws: WhubClientError.api(status: 409, code: "already_exists", message: "同じ名前の項目が既に存在します。")) {
            try await client.files.createFile(root: root, path: "folder/renamed.txt")
        }
        await #expect(throws: WhubClientError.invalidPath) {
            try await client.files.trash(root: root, path: "../outside")
        }
    }
}

#if os(Linux)
@Test func filesTrashCanBeRestored() async throws {
    let fixture = try await FilesFixture()
    defer { withExtendedLifetime(fixture) {} }
    let fm = FileManager.default
    let fileName = "whub-trash-test-\(UUID().uuidString)"
    let folderName = "whub-trash-test-\(UUID().uuidString)"
    let file = fixture.first.appendingPathComponent(fileName)
    let folder = fixture.first.appendingPathComponent(folderName)
    let content = Data("restore me".utf8)
    try content.write(to: file)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    try content.write(to: folder.appendingPathComponent("nested"))

    @Sendable func restore(_ name: String, destination: URL) throws {
        for _ in 0..<30 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["gio", "move", "--no-target-directory", "trash:///\(name)", destination.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Issue.record("ゴミ箱から復元できません: \(name)")
    }

    try await fixture.app.test(.live) { transport in
        let port = try #require(transport.port)
        let client = try WhubClient(baseURL: #require(URL(string: "http://localhost:\(port)")))
        for name in [fileName, folderName] {
            try await client.files.trash(root: fixture.first.path, path: name)
            #expect(!fm.fileExists(atPath: fixture.first.appendingPathComponent(name).path))
            try restore(name, destination: fixture.first.appendingPathComponent(name))
        }
    }
    #expect(try Data(contentsOf: file) == content)
    #expect(try Data(contentsOf: folder.appendingPathComponent("nested")) == content)
}
#endif

@Test func filesKeepSymlinkAndTextRestrictions() async throws {
    let fixture = try await FilesFixture()
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
    let fixture = try await FilesFixture()
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
    let fixture = try await FilesFixture()
    let file = fixture.first.appendingPathComponent("file")
    let files = try FilesService(root: fixture.first.path)
    let service = FilesWriter(files: files)
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
    #expect(["one", "two"].contains(try FilesReader(files: files).readText(path: "file")))
}

@Test func filesWriteRefusesUnsafeUnsupportedAndUnwritableTargetsWithoutChangingFiles() async throws {
    let fixture = try await FilesFixture()
    let fm = FileManager.default
    let file = fixture.first.appendingPathComponent("file")
    try Data("base".utf8).write(to: file)
    try fm.createSymbolicLink(at: fixture.first.appendingPathComponent("link"), withDestinationURL: fixture.second)
    try fm.createSymbolicLink(at: fixture.first.appendingPathComponent("file-link"), withDestinationURL: file)
    try Data("outside".utf8).write(to: fixture.second.appendingPathComponent("file"))
    let service = try FilesWriter(files: FilesService(root: fixture.first.path))
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
    let fixture = try await FilesFixture()
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


@Test(arguments: [false, true])
func filesWriteRejectsExtraMetadataWithoutReplacingOriginal(acl: Bool) async throws {
    let fixture = try await FilesFixture()
    let file = fixture.first.appendingPathComponent("file")
    try Data("base".utf8).write(to: file)
    let fd = open(file.path, O_RDWR | O_CLOEXEC)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var before = stat()
    #expect(fstat(fd, &before) == 0)
    #if os(Linux)
    let symbol = try #require(dlsym(nil, "fsetxattr"))
    let set = unsafeBitCast(symbol, to: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafeRawPointer?, Int, Int32) -> Int32).self)
    let name = acl ? "system.posix_acl_access" : "user.whub-test"
    // ACL version, owner, named user, group, mask, other (Linux's on-disk little-endian format).
    let entries: [UInt32] = [2, 0x00060001, .max, 0x00040002, getuid() + 1,
                              0x00040004, .max, 0x00040010, .max, 0x00000020, .max].map { $0.littleEndian }
    let attribute = acl ? entries.withUnsafeBytes { Data($0) } : Data("keep me".utf8)
    let result = attribute.withUnsafeBytes { bytes in
        name.withCString { set(fd, $0, bytes.baseAddress, bytes.count, 0) }
    }
    #expect(result == 0)
    let getSymbol = try #require(dlsym(nil, "fgetxattr"))
    let get = unsafeBitCast(getSymbol, to: (@convention(c) (Int32, UnsafePointer<CChar>, UnsafeMutableRawPointer?, Int) -> Int).self)
    func metadata() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { buffer in
            name.withCString { get(fd, $0, buffer.baseAddress, buffer.count) }
        }
        #expect(count >= 0)
        return Data(bytes.prefix(max(count, 0)))
    }
    #else
    if acl {
        var access = acl_init(1)
        _ = try #require(access)
        defer { if let access { acl_free(UnsafeMutableRawPointer(access)) } }
        var entry: acl_entry_t?
        #expect(acl_create_entry(&access, &entry) == 0)
        let entryValue = try #require(entry)
        #expect(acl_set_tag_type(entryValue, ACL_EXTENDED_ALLOW) == 0)
        var qualifier = UUID().uuid
        #expect(acl_set_qualifier(entryValue, &qualifier) == 0)
        var permissions: acl_permset_t?
        #expect(acl_get_permset(entryValue, &permissions) == 0)
        let permissionSet = try #require(permissions)
        let accessValue = try #require(access)
        #expect(acl_add_perm(permissionSet, ACL_READ_DATA) == 0)
        #expect(acl_set_fd_np(fd, accessValue, ACL_TYPE_EXTENDED) == 0)
    } else {
        let data = Data("keep me".utf8)
        #expect(data.withUnsafeBytes { fsetxattr(fd, "user.whub-test", $0.baseAddress, $0.count, 0, 0) } == 0)
    }
    func metadata() throws -> Data {
        if acl {
            let access = try #require(acl_get_fd_np(fd, ACL_TYPE_EXTENDED))
            defer { acl_free(UnsafeMutableRawPointer(access)) }
            let text = try #require(acl_to_text(access, nil))
            defer { acl_free(text) }
            return Data(String(cString: text).utf8)
        }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { fgetxattr(fd, "user.whub-test", $0.baseAddress, $0.count, 0, 0) }
        #expect(count >= 0)
        return Data(bytes.prefix(max(count, 0)))
    }
    #endif
    let originalMetadata = try metadata()
    try await fixture.app.test(.router) { client in
        let body = try JSONEncoder().encode(["expectedText": "base", "text": "changed"])
        let response = try await client.execute(uri: fixture.uri("write", root: fixture.first, path: "file"), method: .put,
                                               headers: [.contentType: "application/json"], body: .init(bytes: body))
        #expect(response.status == .unprocessableContent)
        let error = try JSONDecoder().decode([String: [String: String]].self, from: Data(response.body.readableBytesView))
        #expect(error["error"]?["code"] == "unsupported_metadata")
    }
    var after = stat()
    #expect(stat(file.path, &after) == 0)
    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
    #expect(try Data(contentsOf: file) == Data("base".utf8))
    #expect(try metadata() == originalMetadata)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.first.path) == ["file"])
}
