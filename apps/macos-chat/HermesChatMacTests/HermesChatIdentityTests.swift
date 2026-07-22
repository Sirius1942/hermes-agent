import XCTest
@testable import HermesChatMac

final class HermesChatIdentityTests: XCTestCase {
    func testProductIdentityIsStableAndUsesChatOnlyNamespaces() {
        XCTAssertEqual(HermesChatIdentity.productID, "hermes-chat-macos")
        XCTAssertEqual(HermesChatIdentity.bundleIdentifier, "com.nousresearch.hermes.chat.macos")
        XCTAssertEqual(
            HermesChatIdentity.preferencesSuite,
            "com.nousresearch.hermes.chat.macos.preferences"
        )
        XCTAssertEqual(
            HermesChatIdentity.keychainService,
            "com.nousresearch.hermes.chat.macos.keychain"
        )
        XCTAssertEqual(HermesChatIdentity.urlScheme, "hermes-chat")
        XCTAssertEqual(HermesChatIdentity.autoStartLocalHermesKey, "autoStartLocalHermes")
        XCTAssertEqual(
            HermesChatIdentity.localHermesExecutablePathKey,
            "localHermesExecutablePath"
        )
        XCTAssertFalse(HermesChatIdentity.productID.contains("admin"))
        XCTAssertFalse(HermesChatIdentity.preferencesSuite.contains("admin"))
        XCTAssertFalse(HermesChatIdentity.keychainService.contains("admin"))
    }

    func testHostedAppInfoPlistMatchesChatIdentity() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Hermes Chat")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, HermesChatIdentity.bundleIdentifier)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [HermesChatIdentity.urlScheme])
    }
}
