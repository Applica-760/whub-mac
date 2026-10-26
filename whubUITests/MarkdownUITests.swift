// テスト一覧:
// - testPreviewDisplaysSelectedFileAndCodeCopyButton(): [MD-F-005] [MD-F-006]

import XCTest

final class MarkdownUITests: XCTestCase {
    @MainActor
    func testPreviewDisplaysSelectedFileAndCodeCopyButton() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whub-markdown-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        for name in ["First", "Second"] {
            try Data("# \(name) document\n\n```swift\nlet value = \"\(name)\"\n```\n".utf8)
                .write(to: directory.appendingPathComponent(name + ".md"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--markdown-ui-test"]
        app.launchEnvironment["WHUB_UI_TEST_DIRECTORY"] = directory.path
        addTeardownBlock { await MainActor.run { app.terminate() } }

        for appearance in ["light", "dark"] {
            app.launchEnvironment["WHUB_UI_TEST_APPEARANCE"] = appearance
            app.launch()
            let window = app.windows["Markdown UI Test"]
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            for (index, name) in ["First", "Second"].enumerated() {
                window.typeKey(String(index + 1), modifierFlags: .command)
                let toggle = window.buttons["markdown.preview.toggle"]
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                XCTAssertEqual(toggle.label, "Show Preview")
                toggle.click()

                let preview = window.textViews["Markdown Preview"]
                XCTAssertTrue(preview.waitForExistence(timeout: 5))
                let content = try XCTUnwrap(preview.value as? String)
                XCTAssertTrue(content.contains(name + " document"), content)
                XCTAssertFalse(content.contains((name == "First" ? "Second" : "First") + " document"))
                let copy = window.buttons["markdown.code.copy"]
                XCTAssertTrue(copy.waitForExistence(timeout: 5), window.debugDescription)
                XCTAssertEqual(copy.label, "コードをコピー")
                XCTAssertTrue(copy.isEnabled && copy.isHittable)
                XCTAssertGreaterThan(copy.frame.width, 0)
                XCTAssertGreaterThan(copy.frame.height, 0)
                XCTAssertEqual(toggle.label, "Hide Preview")
                toggle.click()
                XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            }
            app.terminate()
        }
    }
}
