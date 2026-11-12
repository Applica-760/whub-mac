import Foundation
import Testing
@testable import whub

@Suite @MainActor
struct BrowserIssuesTests {
    @Test func reusesIssueAndEmptyTabs() throws {
        let store = BrowserStore()
        let root = try #require(URL(string: "https://github.com/owner/repo/issues"))
        let initial = store.selectedSessionID
        store.openIssues(root)
        #expect(store.sessions.count == 1)
        #expect(store.selectedSessionID == initial)
        store.add()
        store.openIssues(root)
        #expect(store.sessions.count == 2)
        #expect(store.selectedSessionID == initial)
    }

    @Test func matchesOnlyIssuePath() throws {
        let root = try #require(URL(string: "https://github.com/owner/repo/issues"))
        for value in ["https://github.com/owner/repo/issues?state=open", "https://github.com/owner/repo/issues/148"] {
            #expect(BrowserStore.isIssuesURL(try #require(URL(string: value)), under: root))
        }
        for value in ["https://github.com/owner/repo/issues-extra", "https://github.com/owner/other/issues/148",
                      "https://example.com/owner/repo/issues/148"] {
            #expect(!BrowserStore.isIssuesURL(try #require(URL(string: value)), under: root))
        }
    }

    @Test func resolvesGitHubRepositoryURLs() {
        let expected = URL(string: "https://github.com/owner/repo/issues")
        for value in ["https://github.com/owner/repo", "https://github.com/owner/repo.git",
                      "git@github.com:owner/repo.git", "ssh://git@github.com/owner/repo.git"] {
            #expect(BrowserStore.githubIssuesURL(value) == expected)
        }
        for value in ["", "https://gitlab.com/owner/repo", "https://github.com/owner", "https://github.com/owner/repo/issues"] {
            #expect(BrowserStore.githubIssuesURL(value) == nil)
        }
    }
}
