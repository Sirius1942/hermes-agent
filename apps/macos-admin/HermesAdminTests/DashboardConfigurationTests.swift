import XCTest
@testable import HermesAdmin

final class DashboardConfigurationTests: XCTestCase {
    func testNormalizesHostAndAddsSchemeAndSlash() {
        let url = DashboardURLBuilder.normalize("127.0.0.1:9119")
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:9119/")
    }

    func testRejectsUnsupportedSchemes() {
        XCTAssertNil(DashboardURLBuilder.normalize("file:///tmp/dashboard"))
        XCTAssertNil(DashboardURLBuilder.normalize("javascript:alert(1)"))
    }

    func testBuildsStatusURLUnderBasePath() {
        let dashboard = DashboardURLBuilder.normalize("https://example.com/hermes")!
        XCTAssertEqual(
            DashboardURLBuilder.statusURL(for: dashboard)?.absoluteString,
            "https://example.com/hermes/api/status"
        )
    }

    func testLocalDashboardRecognition() {
        var configuration = DashboardConfiguration.default
        XCTAssertTrue(configuration.isLocalDashboard)
        configuration.dashboardURLString = "https://agent.example.com/"
        XCTAssertFalse(configuration.isLocalDashboard)
    }

    func testLocalHTTPSCanBeConnectedButIsNotAValidAutoStartTarget() async {
        let controller = await DashboardProcessController()
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let dashboard = URL(string: "https://127.0.0.1:9443/")!

        do {
            try await controller.startDashboard(
                executableURL: executable,
                dashboardURL: dashboard
            )
            XCTFail("本地 HTTPS 地址不应由 HTTP Dashboard 启动器处理")
        } catch let error as DashboardProcessError {
            XCTAssertEqual(
                error.localizedDescription,
                "只能自动启动使用 HTTP 的本机 Dashboard；HTTPS 或远程地址必须由服务器端自行运行。"
            )
        } catch {
            XCTFail("收到非预期错误：\(error)")
        }
    }
}
