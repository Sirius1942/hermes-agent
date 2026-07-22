import XCTest
@testable import HermesIOS

final class GatewayURLTests: XCTestCase {
    func testBuildsSecureWebSocketPathAndToken() {
        let url = GatewayURL.websocketURL(
            serverURL: URL(string: "https://example.test/hermes")!,
            token: "a/b c"
        )
        XCTAssertEqual(url?.absoluteString, "wss://example.test/hermes/api/ws?token=a%2Fb%20c")
    }

    func testTicketTakesTheSamePath() {
        let url = GatewayURL.websocketURL(
            serverURL: URL(string: "http://127.0.0.1:9119")!,
            ticket: "one-time"
        )
        XCTAssertEqual(url?.absoluteString, "ws://127.0.0.1:9119/api/ws?ticket=one-time")
    }
}
