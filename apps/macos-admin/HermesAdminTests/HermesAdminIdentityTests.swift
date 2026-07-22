import XCTest
@testable import HermesAdmin

final class HermesAdminIdentityTests: XCTestCase {
    func testProductIdentityIsStableAndUsesAdminOnlyNamespaces() {
        XCTAssertEqual(HermesAdminIdentity.productID, "hermes-admin-macos")
        XCTAssertEqual(HermesAdminIdentity.bundleIdentifier, "com.nousresearch.hermes.admin.macos")
        XCTAssertEqual(
            HermesAdminIdentity.preferencesSuite,
            "com.nousresearch.hermes.admin.macos.preferences"
        )
        XCTAssertEqual(
            HermesAdminIdentity.keychainService,
            "com.nousresearch.hermes.admin.macos.keychain"
        )
        XCTAssertEqual(HermesAdminIdentity.urlScheme, "hermes-admin")
        XCTAssertFalse(HermesAdminIdentity.productID.contains("chat"))
        XCTAssertFalse(HermesAdminIdentity.preferencesSuite.contains("chat"))
        XCTAssertFalse(HermesAdminIdentity.keychainService.contains("chat"))
    }

    func testHostedAppInfoPlistMatchesAdminIdentity() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Hermes Admin")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, HermesAdminIdentity.bundleIdentifier)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [HermesAdminIdentity.urlScheme])
    }

    @MainActor
    func testWindowTitleAlwaysKeepsAdminProductIdentity() {
        let model = AppModel()

        XCTAssertEqual(model.pageTitle, "Hermes Admin")
        model.reportPageTitle(nil)
        XCTAssertEqual(model.pageTitle, "Hermes Admin")
        model.reportPageTitle("Hermes")
        XCTAssertEqual(model.pageTitle, "Hermes Admin")
        model.reportPageTitle("会话")
        XCTAssertEqual(model.pageTitle, "Hermes Admin — 会话")
        model.reportPageTitle("Hermes Admin — 日志")
        XCTAssertEqual(model.pageTitle, "Hermes Admin — 日志")
    }
}
