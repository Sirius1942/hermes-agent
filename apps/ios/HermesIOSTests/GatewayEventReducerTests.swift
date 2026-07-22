import XCTest
@testable import HermesIOS

final class GatewayEventReducerTests: XCTestCase {
    func testWorkspaceStateMachineCoversSessionStreamingPromptStopAndRecovery() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.beginConnect)
        XCTAssertEqual(workspace.phase, .connecting)
        workspace.apply(.connectionChanged(.ready))
        XCTAssertEqual(workspace.phase, .ready)
        workspace.apply(.beginSessionLoad)
        XCTAssertEqual(workspace.phase, .loadingSession)
        workspace.apply(.sessionLoadCompleted)
        XCTAssertEqual(workspace.phase, .ready)
        workspace.apply(.beginSubmit)
        XCTAssertEqual(workspace.phase, .streaming)
        workspace.apply(.promptRequested)
        XCTAssertEqual(workspace.phase, .awaitingInput)
        workspace.apply(.promptResponded)
        XCTAssertEqual(workspace.phase, .streaming)
        workspace.apply(.beginStop)
        XCTAssertEqual(workspace.phase, .stopping)
        workspace.apply(.stopCompleted)
        XCTAssertEqual(workspace.phase, .interrupted)
        workspace.apply(.beginRecovery)
        workspace.apply(.connectionChanged(.connecting))
        workspace.apply(.connectionChanged(.ready))
        XCTAssertEqual(workspace.phase, .recovering)
        workspace.apply(.recoveryCompleted)
        XCTAssertEqual(workspace.phase, .ready)
    }

    func testProviderSetupErrorBecomesConfigurationRequiredAndKeepsRawDiagnosticSeparate() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.beginSubmit)
        workspace.apply(.turnFailed("agent init failed: No inference provider configured"))
        XCTAssertEqual(workspace.phase, .configurationRequired)
        XCTAssertEqual(
            workspace.providerConfigurationIssue?.summary,
            "尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。"
        )
        XCTAssertEqual(
            workspace.providerConfigurationIssue?.diagnostic,
            "agent init failed: No inference provider configured"
        )
        workspace.apply(.beginSubmit)
        XCTAssertEqual(workspace.phase, .streaming)
        XCTAssertNil(workspace.providerConfigurationIssue)
    }

    func testStopAndPromptFailuresReturnToActionablePhases() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.beginSubmit)
        workspace.apply(.beginStop)
        workspace.apply(.stopFailed)
        XCTAssertEqual(workspace.phase, .streaming)
        workspace.apply(.promptRequested)
        workspace.apply(.promptResponseFailed)
        XCTAssertEqual(workspace.phase, .awaitingInput)
    }

    func testEqualConsecutiveDeltasAreBothAppliedWithoutAnEventID() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(GatewayEvent(type: "message.start", sessionID: "s1", payload: .object(["id": .string("m1")])), to: &state)
        let delta = GatewayEvent(type: "message.delta", sessionID: "s1", payload: .object(["id": .string("m1"), "text": .string("Hi")]))
        reducer.apply(delta, to: &state)
        reducer.apply(delta, to: &state)
        XCTAssertEqual(state.messages.first?.text, "HiHi")
        XCTAssertTrue(state.messages.first?.isStreaming == true)
    }

    func testExplicitlyIdentifiedDuplicateDeltaIsAppliedOnlyOnce() {
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
            payload: .object([
                "id": .string("m1"),
                "event_id": .string("event-1"),
                "text": .string("Hi"),
            ])
        )
        reducer.apply(delta, to: &state)
        reducer.apply(delta, to: &state)
        XCTAssertEqual(state.messages.first?.text, "Hi")
    }

    func testLateEventFromAnotherSessionCannotPolluteActiveSession() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(GatewayEvent(type: "message.start", sessionID: "s2", payload: .object(["id": .string("m2")])), to: &state)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testApprovalRequestIsPendingAndSecretPromptIsNotRenderedAsMessage() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(GatewayEvent(type: "secret.request", sessionID: "s1", payload: .object([
            "request_id": .string("r1"), "prompt": .string("输入 token")
        ])), to: &state)
        XCTAssertEqual(state.pendingApproval?.id, "r1")
        XCTAssertEqual(state.pendingApproval?.sessionID, "s1")
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testClarifyChoicesAndApprovalCommandArePreservedForTheHumanDecision() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "clarify.request",
                sessionID: "s1",
                payload: .object([
                    "request_id": .string("clarify-1"),
                    "question": .string("选择环境"),
                    "choices": .array([.string("开发"), .string("测试")]),
                ])
            ),
            to: &state
        )
        XCTAssertEqual(state.pendingApproval?.choices, ["开发", "测试"])

        reducer.apply(
            GatewayEvent(
                type: "approval.request",
                sessionID: "s1",
                payload: .object([
                    "description": .string("命令需要确认"),
                    "command": .string("rm -rf ./generated-cache"),
                ])
            ),
            to: &state
        )
        XCTAssertEqual(state.pendingApproval?.prompt, "命令需要确认")
        XCTAssertEqual(state.pendingApproval?.detail, "rm -rf ./generated-cache")
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testToolLifecyclePreservesContextAndMarksExplicitErrorsAsFailed() {
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
                type: "tool.progress",
                sessionID: "s1",
                payload: .object([
                    "tool_id": .string("tool-1"),
                    "summary": .string("编译中"),
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
                    "result": .object(["error": .string("编译失败")]),
                    "duration_s": .number(1.25),
                ])
            ),
            to: &state
        )

        XCTAssertEqual(state.toolActivities.count, 1)
        XCTAssertEqual(state.toolActivities[0].name, "terminal")
        XCTAssertEqual(state.toolActivities[0].context, "swift test")
        XCTAssertEqual(state.toolActivities[0].summary, "编译中")
        XCTAssertEqual(state.toolActivities[0].status, .failed)
        XCTAssertEqual(state.toolActivities[0].durationSeconds, 1.25)
        XCTAssertTrue(state.messages.isEmpty)
    }

    func testHistoryRoutesToolRowsToInspectorAndNeverCreatesBlankChatMessages() {
        let history = GatewayHistoryDecoder.decode(
            .object([
                "messages": .array([
                    .object(["role": .string("system"), "text": .string("private system prompt")]),
                    .object(["role": .string("user"), "text": .string("检查项目")]),
                    .object([
                        "role": .string("tool"),
                        "name": .string("terminal"),
                        "context": .string("git status --short"),
                        "result": .string("raw output must not be retained"),
                    ]),
                    .object(["role": .string("assistant"), "text": .string("项目已检查")]),
                ])
            ])
        )

        XCTAssertEqual(history.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(history.messages.map(\.text), ["检查项目", "项目已检查"])
        XCTAssertEqual(history.toolActivities.count, 1)
        XCTAssertEqual(history.toolActivities[0].context, "git status --short")
        XCTAssertFalse(String(describing: history).contains("raw output must not be retained"))
        XCTAssertFalse(String(describing: history).contains("private system prompt"))
    }

    func testBackendEventsWithoutMessageIDUseTheActiveStreamingMessage() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(GatewayEvent(type: "message.start", sessionID: "s1", payload: nil), to: &state)
        reducer.apply(GatewayEvent(type: "message.delta", sessionID: "s1", payload: .object(["text": .string("真实回复")])), to: &state)
        reducer.apply(GatewayEvent(type: "message.complete", sessionID: "s1", payload: .object(["text": .string("真实回复")])), to: &state)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].text, "真实回复")
        XCTAssertFalse(state.messages[0].isStreaming)
    }

    func testInitializationErrorWithoutMessageStartIsVisible() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "error",
                sessionID: "s1",
                payload: .object(["message": .string("模型凭据未配置")])
            ),
            to: &state
        )

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].role, "assistant")
        XCTAssertEqual(state.messages[0].error, "模型凭据未配置")
        XCTAssertFalse(state.messages[0].isStreaming)
    }

    func testEquivalentInitializationErrorsAreCollapsed() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "s1")
        reducer.apply(
            GatewayEvent(
                type: "error",
                sessionID: "s1",
                payload: .object(["message": .string("agent init failed: No inference provider configured")])
            ),
            to: &state
        )
        reducer.apply(
            GatewayEvent(
                type: "error",
                sessionID: "s1",
                payload: .object(["message": .string("No inference provider configured")])
            ),
            to: &state
        )

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(
            state.messages[0].error,
            "尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。"
        )
        XCTAssertFalse(state.messages[0].error?.contains("No inference provider configured") ?? true)
    }

    func testPromptResponsesMatchHermesGatewayContracts() {
        let approval = ApprovalRequest(id: "ignored", kind: "approval.request", prompt: "允许执行？", sessionID: "s1")
        let approvalResponse = GatewayPromptResponse(request: approval, accepted: true, value: nil)
        XCTAssertEqual(approvalResponse.method, "approval.respond")
        XCTAssertEqual(approvalResponse.params.objectValue?["choice"], .string("once"))
        XCTAssertEqual(approvalResponse.params.objectValue?["session_id"], .string("s1"))

        let clarify = ApprovalRequest(id: "r2", kind: "clarify.request", prompt: "选择？", sessionID: "s1")
        let clarifyResponse = GatewayPromptResponse(request: clarify, accepted: true, value: "选项 A")
        XCTAssertEqual(clarifyResponse.method, "clarify.respond")
        XCTAssertEqual(clarifyResponse.params.objectValue?["request_id"], .string("r2"))
        XCTAssertEqual(clarifyResponse.params.objectValue?["answer"], .string("选项 A"))

        let secret = ApprovalRequest(id: "r3", kind: "secret.request", prompt: "输入 token", sessionID: "s1")
        let secretResponse = GatewayPromptResponse(request: secret, accepted: true, value: "secret-value")
        XCTAssertEqual(secretResponse.method, "secret.respond")
        XCTAssertEqual(secretResponse.params.objectValue?["request_id"], .string("r3"))
        XCTAssertEqual(secretResponse.params.objectValue?["value"], .string("secret-value"))

        let sudo = ApprovalRequest(id: "r4", kind: "sudo.request", prompt: "输入密码", sessionID: "s1")
        let sudoResponse = GatewayPromptResponse(request: sudo, accepted: true, value: "sudo-value")
        XCTAssertEqual(sudoResponse.method, "sudo.respond")
        XCTAssertEqual(sudoResponse.params.objectValue?["request_id"], .string("r4"))
        XCTAssertEqual(sudoResponse.params.objectValue?["password"], .string("sudo-value"))
    }
}
