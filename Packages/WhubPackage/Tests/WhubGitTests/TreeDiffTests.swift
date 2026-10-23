import Foundation
import Testing
@testable import WhubGit

struct TreeDiffTests {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: false)
    }

    @Test func buildsSharedParentsAndPreservesDeletedFiles() throws {
        let tree = TreeDiff.tree(for: [
            url("/repo/src/components/Button.swift"): .modified,
            url("/repo/src/utils.swift"): .deleted,
            url("/repo/README.md"): .added,
            url("/repo/src/components/Label.swift"): .added,
        ], under: url("/repo"))
        #expect(tree.url.path == "/repo")
        #expect(tree.change == nil)
        #expect(tree.children.map(\.url.lastPathComponent) == ["README.md", "src"])
        let src = try #require(tree.children.last)
        #expect(src.change == nil)
        #expect(src.children.map(\.url.lastPathComponent) == ["components", "utils.swift"])
        #expect(src.children.last?.change == .deleted)
        let components = try #require(src.children.first)
        #expect(components.children.map(\.change) == [.modified, .added])
    }

    @Test func confinesTreeToRootAndNormalizesPaths() {
        let tree = TreeDiff.tree(for: [
            url("/repo-other/outside.swift"): .added,
            url("/repo/../outside.swift"): .deleted,
            url("/repo/sub/../inside.swift"): .modified,
        ], under: url("/repo"))
        #expect(tree.children.map(\.url.path) == ["/repo/inside.swift"])
        #expect(TreeDiff.tree(for: [:], under: url("/repo")).children.isEmpty)
    }

    @Test func supportsFilesystemRootAndFileReplacedByDirectory() throws {
        let tree = TreeDiff.tree(for: [
            url("/item"): .deleted,
            url("/item/new.swift"): .added,
        ], under: url("/"))
        let item = try #require(tree.children.first)
        #expect(tree.children.count == 1)
        #expect(item.change == .deleted)
        #expect(item.children.map(\.change) == [.added])
    }
}
