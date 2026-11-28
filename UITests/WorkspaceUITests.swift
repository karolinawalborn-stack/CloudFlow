import XCTest

final class WorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-fixtures", "--preview-page", page]
        app.launch()
        return app
    }

    func testImportAndKeyboardKeepControlsReachable() {
        let app = launch("desk")
        let source = app.textViews["sourceEditor"]
        let action = app.buttons["batchTransferButton"]
        let navigation = app.buttons["tab-tasks"]
        XCTAssertTrue(source.waitForExistence(timeout: 8))
        XCTAssertTrue(source.isHittable, "Import editor is immediately reachable")
        XCTAssertTrue(action.isHittable)
        XCTAssertTrue(navigation.isHittable)
        XCTAssertLessThanOrEqual(action.frame.maxY, navigation.frame.minY, "Action and navigation must not overlap")
        source.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let done = app.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isHittable)
    }

    func testSearchAndSuccessfulLinks() {
        let app = launch("tasks")
        let search = app.textFields["taskSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap(); search.typeText("previewBaidu")
        XCTAssertTrue(app.staticTexts["显示 1 条"].waitForExistence(timeout: 5))
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(app.staticTexts["显示 3 条"].waitForExistence(timeout: 5))
        app.buttons["成功"].tap()
        XCTAssertTrue(app.staticTexts["显示 1 条"].waitForExistence(timeout: 5))
        let bundle = app.buttons["复制筛选内的成功链接"]
        XCTAssertTrue(bundle.isHittable)
        bundle.tap()
        XCTAssertTrue(app.staticTexts["旅行素材合集"].firstMatch.exists)
    }

    func testPartialPublicationExplainsOriginalLinks() {
        let app = launch("copy")
        let copy = app.buttons["copyPublicationButton"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["仍然复制（包含原链接）"].waitForExistence(timeout: 5))
        app.buttons["继续处理任务"].tap()
        app.buttons["发布稿"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "previewOwned")).firstMatch.exists)
    }
}
