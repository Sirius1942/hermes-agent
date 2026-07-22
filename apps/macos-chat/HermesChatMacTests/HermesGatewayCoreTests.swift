import XCTest
@testable import HermesChatMac

final class HermesGatewayCoreTests: XCTestCase {
    @MainActor
    func testGatewayTraceExportsCorrelationWithoutSensitiveValues() throws {
        let secret = "sk-test-secret-value"
        let sessionID = "raw-session-id"
        let recorder = HermesGatewayTraceRecorder(
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        recorder.recordRequest(
            id: "apple-1",
            method: "secret.respond",
            params: .object([
                "session_id": .string(sessionID),
                "request_id": .string("request-raw"),
                "value": .string(secret),
                "password": .string("sudo-secret"),
            ])
        )
        recorder.recordEvent(
            type: "message.delta",
            sessionID: sessionID,
            payload: .object([
                "text": .string("private prompt content"),
                "token": .string(secret),
            ])
        )
        recorder.recordResponse(
            id: "apple-1",
            method: "secret.respond",
            result: .object(["status": .string("ok")])
        )

        let export = recorder.export(
            runID: "run-1",
            releaseID: "release-1",
            buildID: "build-1",
            platform: "macOS",
            pageID: "MAC-PROMPT",
            scenarioID: "APPLE-UX-006",
            sessionID: sessionID
        )
        let data = try JSONEncoder().encode(export)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(export.events.count, 3)
        XCTAssertEqual(export.events[0].fieldNames, ["password", "request_id", "session_id", "value"])
        XCTAssertEqual(export.events[1].eventType, "message.delta")
        XCTAssertEqual(export.sessionIDHash?.count, 64)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("sudo-secret"))
        XCTAssertFalse(encoded.contains("private prompt content"))
        XCTAssertFalse(encoded.contains(sessionID))
        XCTAssertFalse(encoded.contains("request-raw"))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-rpc-trace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        try recorder.write(export, to: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let persisted = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(persisted.contains(secret))
        XCTAssertTrue(persisted.contains("\"events\""))

        let mirror = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-rpc-mirror-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: mirror) }
        let mirroredRecorder = HermesGatewayTraceRecorder(mirrorURL: mirror)
        mirroredRecorder.recordRequest(
            id: "mirror-1",
            method: "secret.respond",
            params: .object(["session_id": .string(sessionID), "value": .string(secret)])
        )
        let mirrored = try String(contentsOf: mirror, encoding: .utf8)
        XCTAssertTrue(mirrored.contains("secret.respond"))
        XCTAssertFalse(mirrored.contains(secret))
        XCTAssertFalse(mirrored.contains(sessionID))

        recorder.reset()
        XCTAssertTrue(recorder.records.isEmpty)
    }

    func testWorkspaceReadyDoesNotOverwriteRecoveringOrConfigurationRequired() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.beginRecovery)
        workspace.apply(.connectionChanged(.ready))
        XCTAssertEqual(workspace.phase, .recovering)
        workspace.apply(.turnFailed("No Hermes provider is configured."))
        XCTAssertEqual(workspace.phase, .configurationRequired)
        workspace.apply(.connectionChanged(.ready))
        XCTAssertEqual(workspace.phase, .configurationRequired)
    }

    func testBuildsSecureWebSocketPathAndEscapesToken() {
        let url = GatewayURL.websocketURL(
            serverURL: URL(string: "https://example.test/hermes")!,
            token: "a/b c"
        )
        XCTAssertEqual(url?.absoluteString, "wss://example.test/hermes/api/ws?token=a%2Fb%20c")
    }

    func testEqualConsecutiveDeltasAreNotDiscarded() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "message.start",
                sessionID: "s1",
                payload: .object(["id": .string("m1")])
            ),
            to: &state
        )
        let delta = GatewayEvent(
            type: "message.delta",
            sessionID: "s1",
            payload: .object(["id": .string("m1"), "text": .string("哈")])
        )
        reducer.apply(delta, to: &state)
        reducer.apply(delta, to: &state)
        XCTAssertEqual(state.messages.first?.text, "哈哈")
    }

    func testPromptResponsesUseHermesMethods() {
        let request = ApprovalRequest(
            id: "request-1",
            kind: "clarify.request",
            prompt: "请选择",
            sessionID: "s1"
        )
        let response = GatewayPromptResponse(request: request, accepted: true, value: "A")
        XCTAssertEqual(response.method, "clarify.respond")
        XCTAssertEqual(response.params.objectValue?["request_id"], .string("request-1"))
        XCTAssertEqual(response.params.objectValue?["answer"], .string("A"))
    }

    func testToolCompletionAndHistoryHydrationStayOutOfChatTranscript() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "tool.start",
                sessionID: "s1",
                payload: .object([
                    "tool_id": .string("tool-1"),
                    "name": .string("terminal"),
                    "context": .string("swift test"),
                ])
            ),
            to: &state
        )
        reducer.apply(
            GatewayEvent(
                type: "tool.complete",
                sessionID: "s1",
                payload: .object([
                    "tool_id": .string("tool-1"),
                    "name": .string("terminal"),
                    "summary": .string("完成"),
                    "result": .object(["success": .bool(true)]),
                ])
            ),
            to: &state
        )

        XCTAssertEqual(state.toolActivities.first?.status, .completed)
        XCTAssertEqual(state.toolActivities.first?.context, "swift test")
        XCTAssertEqual(state.toolActivities.first?.summary, "完成")
        XCTAssertTrue(state.messages.isEmpty)

        let history = GatewayHistoryDecoder.decode(
            .object([
                "messages": .array([
                    .object(["role": .string("user"), "text": .string("开始")]),
                    .object([
                        "role": .string("tool"),
                        "name": .string("terminal"),
                        "context": .string("pwd"),
                    ]),
                    .object(["role": .string("assistant"), "text": .string("完成")]),
                ])
            ])
        )
        XCTAssertEqual(history.messages.map(\.text), ["开始", "完成"])
        XCTAssertEqual(history.toolActivities.map(\.name), ["terminal"])
    }

    func testApprovalCommandClarifyChoicesAndSudoContractArePreserved() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "approval.request",
                sessionID: "s1",
                payload: .object([
                    "description": .string("危险命令"),
                    "command": .string("rm -rf ./cache"),
                ])
            ),
            to: &state
        )
        XCTAssertEqual(state.pendingApproval?.detail, "rm -rf ./cache")

        reducer.apply(
            GatewayEvent(
                type: "clarify.request",
                sessionID: "s1",
                payload: .object([
                    "request_id": .string("clarify-1"),
                    "question": .string("选择"),
                    "choices": .array([.string("A"), .string("B")]),
                ])
            ),
            to: &state
        )
        XCTAssertEqual(state.pendingApproval?.choices, ["A", "B"])

        let request = ApprovalRequest(
            id: "sudo-1",
            kind: "sudo.request",
            prompt: "输入密码",
            sessionID: "s1"
        )
        let response = GatewayPromptResponse(request: request, accepted: true, value: "not-retained")
        XCTAssertEqual(response.method, "sudo.respond")
        XCTAssertEqual(response.params.objectValue?["request_id"], .string("sudo-1"))
        XCTAssertEqual(response.params.objectValue?["password"], .string("not-retained"))
    }
}
