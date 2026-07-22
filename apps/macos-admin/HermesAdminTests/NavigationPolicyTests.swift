import XCTest
@testable import HermesAdmin

final class NavigationPolicyTests: XCTestCase {
    private let dashboard = URL(string: "http://127.0.0.1:9119/")!

    func testAllowsSameOriginRoutes() {
        let candidate = URL(string: "http://127.0.0.1:9119/models")!
        XCTAssertEqual(
            DashboardNavigationPolicy.disposition(for: candidate, dashboardURL: dashboard),
            .allowInWebView
        )
    }

    func testOpensExternalHTTPLinksOutsideWebView() {
        let candidate = URL(string: "https://nousresearch.com/")!
        XCTAssertEqual(
            DashboardNavigationPolicy.disposition(for: candidate, dashboardURL: dashboard),
            .openExternally
        )
    }

    func testKeepsCrossOriginOAuthRedirectInsideWebView() {
        let candidate = URL(string: "https://portal.example.com/oauth/authorize")!
        XCTAssertEqual(
            DashboardNavigationPolicy.disposition(
                for: candidate,
                dashboardURL: dashboard,
                allowsCrossOriginRedirect: true
            ),
            .allowInWebView
        )
    }

    func testRejectsFileAndJavascriptSchemes() {
        for value in ["file:///tmp/x", "javascript:alert(1)", "custom://thing"] {
            let candidate = URL(string: value)!
            XCTAssertEqual(
                DashboardNavigationPolicy.disposition(for: candidate, dashboardURL: dashboard),
                .reject
            )
        }
    }

    func testBrightThemeIsAppScopedAndDoesNotCallBackendThemeAPI() {
        let script = BrightTheme.javascript(enabled: true)
        XCTAssertTrue(script.contains(BrightTheme.styleIdentifier))
        XCTAssertTrue(script.contains("#fff8ec"))
        XCTAssertFalse(script.contains("/api/dashboard/theme"))
    }

    func testWebContentProcessReloadsOnceThenReportsRepeatedTermination() {
        var state = WebContentRecoveryState()
        XCTAssertEqual(state.actionAfterTermination(), .reload)
        XCTAssertEqual(state.actionAfterTermination(), .reportFailure)

        state.didFinishNavigation()
        XCTAssertEqual(state.actionAfterTermination(), .reload)
    }

    func testDownloadDestinationRemovesPathTraversalAndAvoidsOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = DashboardDownloadDestination.unique(
            in: directory,
            suggestedFilename: "../../report.txt"
        )
        XCTAssertEqual(first.deletingLastPathComponent(), directory)
        XCTAssertEqual(first.lastPathComponent, "report.txt")
        try Data("existing".utf8).write(to: first)

        let second = DashboardDownloadDestination.unique(
            in: directory,
            suggestedFilename: "report.txt"
        )
        XCTAssertEqual(second.lastPathComponent, "report 2.txt")
    }

    func testDashboardLaunchCommandNeverUsesGlobalStop() {
        let arguments = DashboardLaunchCommand.arguments(host: "127.0.0.1", port: 19119)
        XCTAssertEqual(
            arguments,
            ["dashboard", "--skip-build", "--no-open", "--host", "127.0.0.1", "--port", "19119"]
        )
        XCTAssertFalse(arguments.contains("--stop"))
    }
}
