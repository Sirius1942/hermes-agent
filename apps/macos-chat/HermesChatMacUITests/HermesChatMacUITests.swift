import XCTest

final class HermesChatMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWorkbenchStartsAsNativeChatAndOpensManagementCenter() {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_CHAT_MAC_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["mac.workbench.root"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["mac.chat.transcript"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.chat.composer"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["mac.session.list"].waitForExistence(timeout: 5),
            "空态和有会话状态都必须暴露稳定的 mac.session.list Accessibility ID"
        )
        XCTAssertEqual(app.webViews.count, 0)

        let management = app.descendants(matching: .any)["mac.management.open"]
        XCTAssertTrue(management.exists)
        management.click()
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.connection"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.provider"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.sessions"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.autostart"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.logs"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mac.management.search"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Hermes Chat macOS 原生工作台"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
