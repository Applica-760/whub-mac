// テスト一覧:
// - readsBinaryWithinLimit(): バイト列とサイズ上限を確認
// - rejectsUnsafeBinaryTargets(): パスとファイル種別の検証を確認

import Foundation
import Testing
@testable import WhubServer

@Suite struct FilesReaderTests {
    @Test func readsBinaryWithinLimit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let reader = try FilesReader(files: FilesService(root: root.path))
        let content = Data(repeating: 0xFF, count: 8 * 1_048_576)
        try content.write(to: file)
        #expect(try reader.readBinary(path: "image.png") == content)

        try (content + Data([0])).write(to: file)
        #expect(throws: FilesError.binaryTooLarge) { try reader.readBinary(path: "image.png") }
    }

    @Test func rejectsUnsafeBinaryTargets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 255]).write(to: root.appendingPathComponent("image"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                   withDestinationPath: "image")
        let reader = try FilesReader(files: FilesService(root: root.path))
        #expect(throws: FilesError.symlinkForbidden) { try reader.readBinary(path: "link") }
        #expect(throws: FilesError.invalidPath) { try reader.readBinary(path: "../image") }
        #expect(throws: FilesError.notRegularFile) { try reader.readBinary(path: "") }
        #expect(throws: FilesError.notFound) { try reader.readBinary(path: "missing") }
    }

    private func makeRoot() throws -> URL {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = package.appendingPathComponent(".build/files-reader-tests/\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
