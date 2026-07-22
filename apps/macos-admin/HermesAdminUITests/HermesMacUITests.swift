import XCTest

final class HermesAdminUITests: XCTestCase {
    private let bundleIdentifier = "com.nousresearch.hermes.admin.macos"
    private let preferencesSuite = "com.nousresearch.hermes.admin.macos.preferences"
    private let configurationKey = "HermesAdmin.Configuration"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try setBrightTheme(true)
    }

    func testConnectsAndTogglesBrightThemeFromToolbar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HERMES_MAC_UI_TESTING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))

        let themeControl = app.descendants(matching: .any)["明快主题"]
        XCTAssertTrue(themeControl.waitForExistence(timeout: 5))
        themeControl.click()

        let preferenceChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (try? self?.brightThemeEnabled()) == false
            },
            object: nil
        )
        wait(for: [preferenceChanged], timeout: 5)

        XCTAssertTrue(app.descendants(matching: .any)["重新加载"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["在浏览器中打开"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["设置"].exists)

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Hermes Admin 工具栏主题切换"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.terminate()
        try setBrightTheme(true)
    }

    private func setBrightTheme(_ enabled: Bool) throws {
        let payload: [String: Any] = [
            "dashboardURLString": "http://127.0.0.1:9119/",
            "hermesExecutablePath": "",
            "autoStartLocalDashboard": true,
            "brightThemeEnabled": enabled,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferencesSuite))
        defaults.set(data, forKey: configurationKey)
        defaults.synchronize()
    }

    private func brightThemeEnabled() throws -> Bool {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferencesSuite))
        let data = try XCTUnwrap(defaults.data(forKey: configurationKey))
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(value?["brightThemeEnabled"] as? Bool)
    }
}
