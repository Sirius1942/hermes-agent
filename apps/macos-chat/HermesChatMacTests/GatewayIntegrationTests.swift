import XCTest
@testable import HermesChatMac

final class GatewayIntegrationTests: XCTestCase {
    @MainActor
    func testInitialConnectionFailureDoesNotRemainConnecting() async throws {
        let gateway = HermesGateway(clientID: "mac-test")
        do {
            try await gateway.connect(
                serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")),
                token: nil,
                timeout: .seconds(2)
            )
            XCTFail("不可达端口不应连接成功")
        } catch {
            guard case .failed(let message) = gateway.state else {
                return XCTFail("连接失败后状态仍是 \(gateway.state)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    @MainActor
    func testRealHermesGatewayListCreateResumeAndInterrupt() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["HERMES_MAC_E2E_URL"],
              let serverURL = URL(string: rawURL)
        else {
            throw XCTSkip("设置 HERMES_MAC_E2E_URL 后运行真实 Hermes 集成测试")
        }

        let gateway = HermesGateway(clientID: "mac-test")
        try await gateway.connect(serverURL: serverURL, token: environment["HERMES_MAC_E2E_TOKEN"])
        XCTAssertEqual(gateway.state, .ready)

        let listed = try await gateway.request(
            method: "session.list",
            params: .object(["limit": .number(5)])
        )
        XCTAssertNotNil(listed.objectValue?["sessions"]?.arrayValue)

        if let storedSessionID = environment["HERMES_APPLE_E2E_SESSION_ID"] {
            let resumed = try await gateway.request(
                method: "session.resume",
                params: .object(["session_id": .string(storedSessionID)])
            )
            XCTAssertEqual(resumed.objectValue?["resumed"], .string(storedSessionID))
            XCTAssertEqual(resumed.objectValue?["messages"]?.arrayValue?.count, 2)
        }

        let created = try await gateway.request(
            method: "session.create",
            params: .object([
                "source": .string("macos"),
                "close_on_disconnect": .bool(true),
            ])
        )
        let sessionID = try XCTUnwrap(created.objectValue?["session_id"]?.stringValue)
        let interrupted = try await gateway.request(
            method: "session.interrupt",
            params: .object(["session_id": .string(sessionID)])
        )
        XCTAssertEqual(interrupted.objectValue?["status"], .string("interrupted"))
        let tracedMethods = gateway.traceRecorder.records.compactMap(\.method)
        XCTAssertTrue(tracedMethods.contains("session.list"))
        XCTAssertTrue(tracedMethods.contains("session.resume"))
        XCTAssertTrue(tracedMethods.contains("session.create"))
        XCTAssertTrue(tracedMethods.contains("session.interrupt"))
        XCTAssertFalse(
            String(describing: gateway.traceRecorder.records).contains(
                environment["HERMES_MAC_E2E_TOKEN"] ?? "test-mvp-token"
            )
        )
        try attachGatewayTrace(
            gateway,
            sessionID: sessionID,
            platform: "macOS",
            pageID: "MAC-WORKBENCH",
            scenarioID: "APPLE-UX-003"
        )
        gateway.disconnect()
    }

    @MainActor
    func testRealSharedChatStoreLoadsAndResumesTheSeededSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawURL = environment["HERMES_MAC_E2E_URL"],
              let storedSessionID = environment["HERMES_APPLE_E2E_SESSION_ID"]
        else {
            throw XCTSkip("设置 Hermes Apple E2E 环境后运行共享 ChatStore 集成测试")
        }
        let store = HermesChatStore(
            source: "macos-test",
            gateway: HermesGateway(clientID: "mac-store-test")
        )
        store.serverText = rawURL
        store.tokenText = environment["HERMES_MAC_E2E_TOKEN"] ?? ""
        await store.connect()
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.sessions.contains(where: { $0.id == storedSessionID }))

        await store.selectSession(storedSessionID)
        XCTAssertNotEqual(store.activeSessionID, storedSessionID)
        XCTAssertEqual(store.activeStoredSessionID, storedSessionID)
        XCTAssertEqual(store.messages.map(\.text), ["跨端恢复测试消息", "跨端恢复测试回复"])
        await store.stop()
        XCTAssertNil(store.operationError)
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.workspacePhase, .interrupted)
        store.disconnect()
    }

    @MainActor
    private func attachGatewayTrace(
        _ gateway: HermesGateway,
        sessionID: String,
        platform: String,
        pageID: String,
        scenarioID: String
    ) throws {
        let export = gateway.traceRecorder.export(
            runID: ProcessInfo.processInfo.environment["HERMES_APPLE_E2E_RUN_ID"]
                ?? "TL06-RPC-E2E",
            releaseID: "HermesApple-MVP-dev",
            buildID: "apple-shared-e2e",
            platform: platform,
            pageID: pageID,
            scenarioID: scenarioID,
            sessionID: sessionID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(export),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "macOS Hermes 脱敏 RPC 轨迹"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
