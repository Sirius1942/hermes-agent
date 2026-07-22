import Foundation
import XCTest

#if os(macOS)
@testable import HermesChatMac
#else
@testable import HermesIOS
#endif

final class HermesConfigurationClientTests: XCTestCase {
    override func tearDown() {
        ConfigurationURLProtocol.handler = nil
        super.tearDown()
    }

    func testProviderOptionsPreserveBasePathProfileAndSessionToken() async throws {
        let client = makeClient(baseURL: "http://127.0.0.1:9127/hermes", profile: "work")
        ConfigurationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/hermes/api/model/options")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "include_unconfigured" })?.value, "1")
            XCTAssertEqual(query?.first(where: { $0.name == "refresh" })?.value, "1")
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "work")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "test-token")
            return Self.response(
                request,
                body: #"{"model":"gpt-test","provider":"openai","providers":[{"name":"OpenAI","slug":"openai","models":["gpt-test"],"authenticated":true}]}"#
            )
        }

        let result = try await client.providerOptions(refresh: true)

        XCTAssertEqual(result.provider, "openai")
        XCTAssertEqual(result.providers.first?.models, ["gpt-test"])
        XCTAssertEqual(result.providers.first?.authenticated, true)
    }

    func testValidateCredentialUsesProtectedJSONEndpoint() async throws {
        let client = makeClient()
        ConfigurationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/providers/validate")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"), "test-token")
            let body = try Self.bodyData(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["key"], "OPENAI_API_KEY")
            XCTAssertEqual(object["value"], "secret-value")
            return Self.response(
                request,
                body: #"{"ok":true,"reachable":true,"message":"","models":["gpt-test"]}"#
            )
        }

        let result = try await client.validateCredential(
            key: "OPENAI_API_KEY",
            value: "secret-value"
        )

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.reachable)
        XCTAssertEqual(result.models, ["gpt-test"])
    }

    func testSaveCredentialAndSetMainModelUseExistingHermesContracts() async throws {
        let client = makeClient()
        var calls: [String] = []
        ConfigurationURLProtocol.handler = { request in
            calls.append(request.url?.path ?? "")
            if request.url?.path == "/api/env" {
                XCTAssertEqual(request.httpMethod, "PUT")
                return Self.response(request, body: #"{"ok":true}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/model/set")
            let body = try Self.bodyData(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["scope"] as? String, "main")
            XCTAssertEqual(object["provider"] as? String, "openai")
            XCTAssertEqual(object["model"] as? String, "gpt-test")
            return Self.response(
                request,
                body: #"{"ok":false,"provider":"openai","model":"gpt-test","confirm_required":true,"confirm_message":"费用较高"}"#
            )
        }

        try await client.saveCredential(key: "OPENAI_API_KEY", value: "secret-value")
        let assignment = try await client.setMainModel(provider: "openai", model: "gpt-test")

        XCTAssertEqual(calls, ["/api/env", "/api/model/set"])
        XCTAssertTrue(assignment.confirmRequired)
        XCTAssertEqual(assignment.confirmMessage, "费用较高")
    }

    func testHTTPErrorReturnsStableLocalizedFailure() async throws {
        let client = makeClient()
        ConfigurationURLProtocol.handler = { request in
            Self.response(request, status: 400, body: #"{"detail":"Provider 配置无效"}"#)
        }

        do {
            _ = try await client.environment()
            XCTFail("HTTP 错误没有抛出")
        } catch let error as HermesConfigurationError {
            XCTAssertEqual(error, .http(status: 400, detail: "Provider 配置无效"))
            XCTAssertEqual(error.localizedDescription, "Provider 配置无效")
        }
    }

    @MainActor
    func testChatStoreLoadsProviderSetupAndDoesNotAutoSubmit() async throws {
        let service = FakeConfigurationService()
        let gateway = HermesGateway(clientID: "provider-store-test")
        let store = HermesChatStore(
            source: "test",
            gateway: gateway,
            makeConfigurationService: { _, _ in service }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: "test-token"
        )

        await store.loadProviderSetup()

        XCTAssertEqual(store.providerOptions?.providers.first?.slug, "openai")
        XCTAssertEqual(store.providerEnvironment["OPENAI_API_KEY"]?.isSet, false)
        XCTAssertFalse(store.isProviderSetupBusy)
        XCTAssertEqual(service.modelAssignmentCalls, 0)
    }

    @MainActor
    func testProviderLoadAndValidationOnlyCommitLatestOperation() async {
        let service = ReentrantConfigurationService()
        let store = HermesChatStore(
            source: "provider-operation-order",
            gateway: HermesGateway(clientID: "provider-operation-order"),
            makeConfigurationService: { _, _ in service }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: nil
        )

        service.suspendNextOptions = true
        let loadTask = Task { await store.loadProviderSetup() }
        let optionsPending = await service.waitUntilOptionsPending()
        XCTAssertTrue(optionsPending)
        _ = await store.saveProviderCredential(
            key: "OPENAI_API_KEY",
            value: "saved-during-load"
        )
        service.completeOptions(model: "old-model", provider: "old-provider")
        await loadTask.value
        XCTAssertNil(store.providerOptions)
        XCTAssertTrue(store.providerEnvironment.isEmpty)
        XCTAssertEqual(service.savedCredentialCount, 1)
        XCTAssertFalse(store.isProviderSetupBusy)
        XCTAssertNil(store.providerSetupError)

        await store.loadProviderSetup(refresh: true)
        XCTAssertEqual(store.providerOptions?.model, "new-model")
        XCTAssertEqual(store.providerOptions?.provider, "new-provider")
        XCTAssertFalse(store.isProviderSetupBusy)
        XCTAssertNil(store.providerSetupError)

        service.suspendNextValidation = true
        let validationTask = Task {
            await store.validateProviderCredential(
                key: "OPENAI_API_KEY",
                value: "old-secret"
            )
        }
        let validationPending = await service.waitUntilValidationPending()
        XCTAssertTrue(validationPending)
        _ = await store.saveProviderCredential(key: "OPENAI_API_KEY", value: "new-secret")
        service.completeValidation(ok: false, message: "旧验证失败")
        let staleValidation = await validationTask.value
        XCTAssertNil(staleValidation)
        XCTAssertEqual(service.savedCredentialCount, 2)
        XCTAssertNil(store.providerSetupError)
        XCTAssertFalse(store.isProviderSetupBusy)
    }

    @MainActor
    func testProviderCancelAndDisconnectInvalidateInFlightOperations() async {
        let service = ReentrantConfigurationService()
        let requester = FakeGatewayRequester()
        requester.handler = { method, _ in
            guard method == "session.create" else {
                throw GatewayError(code: nil, message: "未处理方法 \(method)")
            }
            return .object([
                "session_id": .string("provider-operation-live"),
                "stored_session_id": .string("provider-operation-stored"),
                "messages": .array([]),
            ])
        }
        let gateway = HermesGateway(clientID: "provider-operation-cancel")
        let store = HermesChatStore(
            source: "provider-operation-cancel",
            gateway: gateway,
            gatewayRequester: requester,
            makeConfigurationService: { _, _ in service }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: nil
        )
        await store.createSession()
        gateway.onEvent?(
            GatewayEvent(
                type: "error",
                sessionID: "provider-operation-live",
                payload: .object(["message": .string("No inference provider configured")])
            )
        )
        await Task.yield()
        XCTAssertEqual(store.workspacePhase, .configurationRequired)

        service.suspendNextModelAssignment = true
        let assignmentTask = Task {
            await store.selectMainModel(provider: "openai", model: "stale-model")
        }
        let assignmentPending = await service.waitUntilModelAssignmentPending()
        XCTAssertTrue(assignmentPending)
        store.cancelProviderConfiguration()
        service.completeModelAssignment(provider: "openai", model: "stale-model")
        let staleAssignment = await assignmentTask.value
        XCTAssertNil(staleAssignment)
        XCTAssertEqual(store.workspacePhase, .configurationRequired)
        XCTAssertNotNil(store.providerConfigurationIssue)
        XCTAssertFalse(store.isProviderSetupBusy)

        let disconnectedService = ReentrantConfigurationService()
        let disconnectedStore = HermesChatStore(
            source: "provider-operation-disconnect",
            gateway: HermesGateway(clientID: "provider-operation-disconnect"),
            makeConfigurationService: { _, _ in disconnectedService }
        )
        disconnectedStore.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: nil
        )
        disconnectedService.suspendNextOptions = true
        let disconnectedLoad = Task { await disconnectedStore.loadProviderSetup() }
        let disconnectedOptionsPending = await disconnectedService.waitUntilOptionsPending()
        XCTAssertTrue(disconnectedOptionsPending)
        disconnectedStore.disconnect()
        disconnectedService.completeOptions(model: "stale-model", provider: "stale-provider")
        await disconnectedLoad.value
        XCTAssertNil(disconnectedStore.providerOptions)
        XCTAssertTrue(disconnectedStore.providerEnvironment.isEmpty)
        XCTAssertNil(disconnectedStore.providerSetupError)
        XCTAssertFalse(disconnectedStore.isProviderSetupBusy)
        XCTAssertEqual(disconnectedStore.workspacePhase, .disconnected)
    }

    func testProviderConfigurationSavedWaitsForExplicitRetryAndConnectionReadyCannotOverride() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.turnFailed("No inference provider configured"))
        XCTAssertEqual(workspace.phase, .configurationRequired)
        XCTAssertNotNil(workspace.providerConfigurationIssue)

        workspace.apply(.providerConfigurationSaved)

        XCTAssertEqual(workspace.phase, .providerConfigurationSavedAwaitingRetry)
        XCTAssertNil(workspace.providerConfigurationIssue)

        workspace.apply(.connectionChanged(.ready))
        XCTAssertEqual(workspace.phase, .providerConfigurationSavedAwaitingRetry)

        workspace.apply(.providerRetryRequested)
        XCTAssertEqual(workspace.phase, .ready)
    }

    func testProviderRecoveryPresentationIsLocalizedStableAndNeverAutoRetries() throws {
        let issue = try XCTUnwrap(
            ProviderSetupErrorClassifier.classify(
                "agent init failed: No inference provider configured"
            )
        )
        let ios = issue.presentation(platform: .iOS)
        let mac = issue.presentation(platform: .macOS)

        XCTAssertEqual(ios.title, "模型服务尚未配置")
        XCTAssertEqual(ios.configureActionTitle, "配置服务")
        XCTAssertEqual(ios.diagnosticsActionTitle, "原始诊断")
        XCTAssertEqual(ios.cancelActionTitle, "取消")
        XCTAssertFalse(ios.diagnosticsInitiallyExpanded)
        XCTAssertFalse(ios.allowsAutomaticRetry)
        XCTAssertEqual(
            ios.accessibilityIdentifier(for: .configure),
            "ios.provider.configure"
        )
        XCTAssertEqual(
            ios.accessibilityIdentifier(for: .diagnostics),
            "ios.provider.diagnostics"
        )
        XCTAssertEqual(
            mac.accessibilityIdentifier(for: .configure),
            "mac.provider.configure"
        )
        XCTAssertEqual(
            mac.accessibilityIdentifier(for: .diagnostics),
            "mac.provider.diagnostics"
        )
    }

    func testProviderSavedPresentationOwnsExplicitRetryAction() {
        let ios = ProviderConfigurationSavedPresentation(platform: .iOS)
        let mac = ProviderConfigurationSavedPresentation(platform: .macOS)

        XCTAssertEqual(ios.title, "模型服务已保存")
        XCTAssertEqual(ios.cancelActionTitle, "稍后重试")
        XCTAssertEqual(ios.retryActionTitle, "重新尝试")
        XCTAssertFalse(ios.allowsAutomaticRetry)
        XCTAssertEqual(
            ios.accessibilityIdentifier(for: .cancel),
            "ios.provider.cancel"
        )
        XCTAssertEqual(
            ios.accessibilityIdentifier(for: .retry),
            "ios.provider.retry"
        )
        XCTAssertEqual(
            mac.accessibilityIdentifier(for: .retry),
            "mac.provider.retry"
        )
    }

    func testProviderDiagnosticSanitizerRemovesCredentialShapes() throws {
        let raw = "No inference provider configured; OPENAI_API_KEY=sk-secretvalue123; Authorization: Bearer abc.def.ghi; token='private-token'"
        let issue = try XCTUnwrap(ProviderSetupErrorClassifier.classify(raw))

        XCTAssertTrue(issue.diagnostic.contains("No inference provider configured"))
        XCTAssertTrue(issue.diagnostic.contains("OPENAI_API_KEY=[已隐藏]"))
        XCTAssertTrue(issue.diagnostic.contains("Bearer [已隐藏]"))
        XCTAssertTrue(issue.diagnostic.contains("token=[已隐藏]"))
        XCTAssertFalse(issue.diagnostic.contains("sk-secretvalue123"))
        XCTAssertFalse(issue.diagnostic.contains("abc.def.ghi"))
        XCTAssertFalse(issue.diagnostic.contains("private-token"))
    }

    func testProviderConfigurationCancelKeepsIssueAndRequiresExplicitRetry() {
        var workspace = ChatWorkspaceStateMachine()
        workspace.apply(.turnFailed("No inference provider configured"))
        let issue = workspace.providerConfigurationIssue

        workspace.apply(.providerConfigurationCancelled)

        XCTAssertEqual(workspace.phase, .configurationRequired)
        XCTAssertEqual(workspace.providerConfigurationIssue, issue)
        XCTAssertFalse(issue?.presentation(platform: .iOS).allowsAutomaticRetry ?? true)
    }

    @MainActor
    func testRetryProviderRequestUsesSlashRetryTruncatesFailedExchangeAndSubmitsOnce() async throws {
        let requester = FakeGatewayRequester()
        requester.handler = { method, _ in
            switch method {
            case "session.create":
                return Self.retrySessionResult()
            case "slash.exec":
                return .object([
                    "type": .string("send"),
                    "message": .string("请继续上一项任务"),
                ])
            case "prompt.submit":
                return .object(["accepted": .bool(true)])
            default:
                throw GatewayError(code: nil, message: "未预期请求：\(method)")
            }
        }
        let service = FakeConfigurationService()
        let gateway = HermesGateway(clientID: "provider-retry-success")
        let store = HermesChatStore(
            source: "test",
            gateway: gateway,
            gatewayRequester: requester,
            makeConfigurationService: { _, _ in service }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: "test-token"
        )

        await store.createSession()
        gateway.onEvent?(
            GatewayEvent(
                type: "error",
                sessionID: "retry-live-session",
                payload: .object([
                    "message": .string("No inference provider configured")
                ])
            )
        )
        await Task.yield()
        _ = await store.selectMainModel(provider: "openai", model: "gpt-test")

        XCTAssertEqual(store.workspacePhase, .providerConfigurationSavedAwaitingRetry)
        XCTAssertNotNil(store.providerConfigurationSavedPresentation(platform: .iOS))
        XCTAssertEqual(requester.calls.map(\.method), ["session.create"])

        await store.retryProviderRequest()

        XCTAssertEqual(
            requester.calls.map(\.method),
            ["session.create", "slash.exec", "prompt.submit"]
        )
        let slashParams = requester.calls[1].params?.objectValue
        XCTAssertEqual(slashParams?["session_id"]?.stringValue, "retry-live-session")
        XCTAssertEqual(slashParams?["command"]?.stringValue, "/retry")
        let submitParams = requester.calls[2].params?.objectValue
        XCTAssertEqual(submitParams?["text"]?.stringValue, "请继续上一项任务")
        XCTAssertEqual(
            store.messages.filter { $0.role == "user" && $0.text == "请继续上一项任务" }.count,
            1
        )
        XCTAssertEqual(store.messages.first?.text, "已保留的更早上下文")
        XCTAssertEqual(store.messages.last?.role, "user")
        XCTAssertEqual(store.workspacePhase, .streaming)
        XCTAssertNil(store.providerSetupError)
    }

    @MainActor
    func testRetryProviderRequestRejectsUnexpectedResultWithoutSubmitOrTranscriptMutation() async {
        let requester = FakeGatewayRequester()
        requester.handler = { method, _ in
            switch method {
            case "session.create":
                return Self.retrySessionResult()
            case "slash.exec":
                return .object(["type": .string("exec"), "output": .string("无可重试消息")])
            default:
                throw GatewayError(code: nil, message: "不应提交：\(method)")
            }
        }
        let gateway = HermesGateway(clientID: "provider-retry-failure")
        let store = HermesChatStore(
            source: "test",
            gateway: gateway,
            gatewayRequester: requester,
            makeConfigurationService: { _, _ in FakeConfigurationService() }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: nil
        )

        await store.createSession()
        gateway.onEvent?(
            GatewayEvent(
                type: "error",
                sessionID: "retry-live-session",
                payload: .object([
                    "message": .string("No inference provider configured")
                ])
            )
        )
        await Task.yield()
        _ = await store.selectMainModel(provider: "openai", model: "gpt-test")
        let messagesBeforeRetry = store.messages

        await store.retryProviderRequest()

        XCTAssertEqual(requester.calls.map(\.method), ["session.create", "slash.exec"])
        XCTAssertEqual(store.messages, messagesBeforeRetry)
        XCTAssertEqual(store.workspacePhase, .providerConfigurationSavedAwaitingRetry)
        XCTAssertNotNil(store.providerConfigurationSavedPresentation(platform: .macOS))
        XCTAssertEqual(store.providerSetupError, "Hermes 未返回可重试的上一条消息")
    }

    func testTurnCompletionAndFailureClearOnlyTheActiveSessionsBlockingPrompt() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "active-session")
        let prompt = GatewayEvent(
            type: "secret.request",
            sessionID: "active-session",
            payload: .object([
                "request_id": .string("secret-1"),
                "prompt": .string("输入密钥"),
            ])
        )

        reducer.apply(prompt, to: &state)
        XCTAssertEqual(state.pendingApproval?.id, "secret-1")

        reducer.apply(
            GatewayEvent(type: "message.complete", sessionID: "background-session", payload: nil),
            to: &state
        )
        XCTAssertEqual(state.pendingApproval?.id, "secret-1")

        reducer.apply(
            GatewayEvent(type: "message.complete", sessionID: "active-session", payload: nil),
            to: &state
        )
        XCTAssertNil(state.pendingApproval)

        reducer.apply(prompt, to: &state)
        reducer.apply(
            GatewayEvent(
                type: "error",
                sessionID: "active-session",
                payload: .object(["message": .string("prompt timed out")])
            ),
            to: &state
        )
        XCTAssertNil(state.pendingApproval)
    }

    func testProviderConfigurationErrorUsesLocalizedTranscriptSummary() {
        var reducer = GatewayEventReducer()
        var state = ChatReducerState(activeSessionID: "provider-session")

        reducer.apply(
            GatewayEvent(
                type: "error",
                sessionID: "provider-session",
                payload: .object([
                    "message": .string("No inference provider configured")
                ])
            ),
            to: &state
        )

        XCTAssertEqual(
            state.messages.last?.error,
            "尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。"
        )
        XCTAssertFalse(state.messages.last?.error?.contains("No inference provider configured") ?? true)
    }

    @MainActor
    func testStoreClearsPromptOnStopSessionSwitchAndDisconnectButRetainsFailedResponse() async {
        let gateway = HermesGateway(clientID: "prompt-lifecycle-test")
        let requester = FakeGatewayRequester()
        requester.handler = { method, _ in
            switch method {
            case "session.create":
                return .object([
                    "session_id": .string("live-1"),
                    "stored_session_id": .string("stored-1"),
                    "messages": .array([]),
                ])
            case "session.interrupt":
                return .object(["status": .string("interrupted")])
            case "session.resume":
                return .object([
                    "session_id": .string("live-2"),
                    "resumed": .string("stored-2"),
                    "messages": .array([]),
                ])
            case "secret.respond":
                throw GatewayError(code: 4009, message: "no pending secret request")
            default:
                throw GatewayError(code: nil, message: "未处理方法 \(method)")
            }
        }
        let store = HermesChatStore(
            source: "prompt-lifecycle-test",
            gateway: gateway,
            gatewayRequester: requester
        )
        await store.createSession()

        func secretEvent(_ requestID: String, sessionID: String) -> GatewayEvent {
            GatewayEvent(
                type: "secret.request",
                sessionID: sessionID,
                payload: .object([
                    "request_id": .string(requestID),
                    "prompt": .string("输入敏感内容"),
                ])
            )
        }

        store.applyGatewayEvent(secretEvent("stop-secret", sessionID: "live-1"))
        XCTAssertNotNil(store.pendingApproval)
        await store.stop()
        XCTAssertNil(store.pendingApproval)

        store.applyGatewayEvent(secretEvent("failed-response", sessionID: "live-1"))
        let failedRequest = store.pendingApproval!
        await store.respond(to: failedRequest, accepted: true, value: "temporary-secret")
        XCTAssertEqual(store.pendingApproval?.id, "failed-response")
        XCTAssertEqual(store.workspacePhase, .awaitingInput)

        await store.selectSession("stored-2")
        XCTAssertEqual(store.activeSessionID, "live-2")
        XCTAssertNil(store.pendingApproval)

        store.applyGatewayEvent(secretEvent("disconnect-secret", sessionID: "live-2"))
        XCTAssertNotNil(store.pendingApproval)
        store.disconnect()
        XCTAssertNil(store.pendingApproval)
    }

    @MainActor
    func testReconnectExplicitlyResumesActiveStoredSessionAndPreservesDraft() async {
        let requester = FakeGatewayRequester()
        requester.handler = { method, params in
            switch method {
            case "session.create":
                return .object([
                    "session_id": .string("pre-disconnect-live"),
                    "stored_session_id": .string("reconnect-stored"),
                    "messages": .array([
                        .object([
                            "id": .string("before-disconnect"),
                            "role": .string("assistant"),
                            "content": .string("断线前历史"),
                        ]),
                    ]),
                ])
            case "session.resume":
                XCTAssertEqual(
                    params?.objectValue?["session_id"]?.stringValue,
                    "reconnect-stored"
                )
                return .object([
                    "session_id": .string("post-reconnect-live"),
                    "resumed": .string("reconnect-stored"),
                    "messages": .array([
                        .object([
                            "id": .string("after-reconnect"),
                            "role": .string("assistant"),
                            "content": .string("重连后的持久历史"),
                        ]),
                    ]),
                ])
            default:
                throw GatewayError(code: nil, message: "未处理方法 \(method)")
            }
        }
        let store = HermesChatStore(
            source: "reconnect-resume-test",
            gateway: HermesGateway(clientID: "reconnect-resume-test"),
            gatewayRequester: requester
        )
        await store.createSession()
        store.draft = "重连时必须保留的草稿"

        let resumed = await store.resumeActiveStoredSessionAfterReconnect()

        XCTAssertTrue(resumed)
        XCTAssertEqual(store.activeSessionID, "post-reconnect-live")
        XCTAssertEqual(store.activeStoredSessionID, "reconnect-stored")
        XCTAssertEqual(store.messages.map(\.text), ["重连后的持久历史"])
        XCTAssertEqual(store.draft, "重连时必须保留的草稿")
        XCTAssertEqual(requester.calls.map(\.method), ["session.create", "session.resume"])
    }

    @MainActor
    func testStopFinalizesStreamingMessageAndMarksRunningToolsInterrupted() async {
        let requester = FakeGatewayRequester()
        requester.handler = { method, _ in
            switch method {
            case "session.create":
                return .object([
                    "session_id": .string("stop-live"),
                    "stored_session_id": .string("stop-stored"),
                    "messages": .array([]),
                ])
            case "session.interrupt":
                return .object(["status": .string("interrupted")])
            default:
                throw GatewayError(code: nil, message: "未处理方法 \(method)")
            }
        }
        let store = HermesChatStore(
            source: "stop-finalization-test",
            gateway: HermesGateway(clientID: "stop-finalization-test"),
            gatewayRequester: requester
        )
        await store.createSession()
        store.applyGatewayEvent(
            GatewayEvent(
                type: "message.start",
                sessionID: "stop-live",
                payload: .object(["id": .string("stop-assistant")])
            )
        )
        store.applyGatewayEvent(
            GatewayEvent(
                type: "message.delta",
                sessionID: "stop-live",
                payload: .object([
                    "id": .string("stop-assistant"),
                    "text": .string("已生成的部分内容"),
                ])
            )
        )
        store.applyGatewayEvent(
            GatewayEvent(
                type: "tool.start",
                sessionID: "stop-live",
                payload: .object([
                    "tool_id": .string("stop-tool"),
                    "name": .string("read_file"),
                    "context": .string("读取验收说明"),
                ])
            )
        )

        await store.stop()

        XCTAssertEqual(store.workspacePhase, .interrupted)
        XCTAssertFalse(store.isStreaming)
        XCTAssertEqual(store.messages.last?.text, "已生成的部分内容")
        XCTAssertEqual(store.messages.last?.isStreaming, false)
        XCTAssertEqual(store.toolActivities.last?.status, .interrupted)
        XCTAssertNil(store.generatingToolName)
    }

    @MainActor
    func testControlledWebSocketPromptCompletionErrorAndInterruptNeverLeaveStalePrompt() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://"),
              URL(string: rawURL) != nil
        else {
            throw XCTSkip("设置 HERMES_APPLE_PROMPT_FIXTURE_URL 后运行受控 Prompt 协议 E2E")
        }
        let gateway = HermesGateway(clientID: "prompt-fixture")
        let store = HermesChatStore(source: "prompt-fixture", gateway: gateway)
        store.serverText = rawURL
        await store.connect()
        XCTAssertEqual(store.state, .ready)
        await store.createSession()
        let sessionID = try XCTUnwrap(store.activeSessionID)

        _ = try await gateway.request(
            method: "fixture.prompt_then_complete",
            params: .object(["session_id": .string(sessionID)])
        )
        let completionPromptAppeared = await waitForPrompt(store, present: true)
        XCTAssertTrue(completionPromptAppeared)
        let completionPromptCleared = await waitForPrompt(store, present: false)
        XCTAssertTrue(completionPromptCleared)
        XCTAssertEqual(store.workspacePhase, .ready)

        _ = try await gateway.request(
            method: "fixture.prompt_then_error",
            params: .object(["session_id": .string(sessionID)])
        )
        let errorPromptAppeared = await waitForPrompt(store, present: true)
        XCTAssertTrue(errorPromptAppeared)
        let errorPromptCleared = await waitForPrompt(store, present: false)
        XCTAssertTrue(errorPromptCleared)
        guard case .failed(let message) = store.workspacePhase else {
            return XCTFail("受控 error 后状态应为 failed，当前为 \(store.workspacePhase)")
        }
        XCTAssertEqual(message, "受控失败")

        _ = try await gateway.request(
            method: "fixture.prompt_only",
            params: .object(["session_id": .string(sessionID)])
        )
        let interruptPromptAppeared = await waitForPrompt(store, present: true)
        XCTAssertTrue(interruptPromptAppeared)
        await store.stop()
        XCTAssertNil(store.pendingApproval)
        XCTAssertEqual(store.workspacePhase, .interrupted)
        store.disconnect()
    }

    @MainActor
    func testControlledWebSocketStaleCreateCannotSubmitDraftToLaterSelectedSession() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://"),
              URL(string: rawURL) != nil
        else {
            throw XCTSkip("设置 HERMES_APPLE_PROMPT_FIXTURE_URL 后运行受控 Create/Submit 协议 E2E")
        }
        let gateway = HermesGateway(clientID: "stale-create-fixture")
        let store = HermesChatStore(source: "stale-create-fixture", gateway: gateway)
        store.serverText = rawURL
        await store.connect()
        XCTAssertEqual(store.state, .ready)
        _ = try await gateway.request(method: "fixture.delay_next_create")

        store.draft = "不得发到 B 的草稿"
        let sendTask = Task { await store.send() }
        let createBecamePending = await waitForFixtureCreate(gateway)
        XCTAssertTrue(createBecamePending)

        await store.selectSession("stored-b")
        XCTAssertEqual(store.activeSessionID, "live-stored-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])

        _ = try await gateway.request(method: "fixture.release_create")
        await sendTask.value
        let calls = try await gateway.request(method: "fixture.calls")
        let object = calls.objectValue ?? [:]
        let closed = object["closed_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let submitted = object["submitted_prompts"]?.arrayValue ?? []

        XCTAssertEqual(store.activeSessionID, "live-stored-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])
        XCTAssertEqual(store.draft, "不得发到 B 的草稿")
        XCTAssertEqual(closed, ["stale-created-live"])
        XCTAssertTrue(submitted.isEmpty)
        store.disconnect()
    }

    @MainActor
    func testControlledWebSocketInFlightSubmitFailureAndEventsStayBoundToOriginalSession() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://"),
              URL(string: rawURL) != nil
        else {
            throw XCTSkip("设置 HERMES_APPLE_PROMPT_FIXTURE_URL 后运行在途 Submit 会话隔离 E2E")
        }
        let gateway = HermesGateway(clientID: "submit-session-isolation-fixture")
        let store = HermesChatStore(source: "submit-session-isolation-fixture", gateway: gateway)
        store.serverText = rawURL
        await store.connect()
        XCTAssertEqual(store.state, .ready)
        await store.createSession()
        let sessionA = try XCTUnwrap(store.activeSessionID)

        _ = try await gateway.request(method: "fixture.delay_next_submit")
        store.draft = "只属于 A 的文本"
        let sendA = Task { await store.send() }
        let submitABecamePending = await waitForFixtureSubmit(gateway)
        XCTAssertTrue(submitABecamePending)

        await store.selectSession("stored-b")
        XCTAssertEqual(store.activeSessionID, "live-stored-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])
        XCTAssertFalse(store.isStreaming)
        XCTAssertEqual(store.workspacePhase, .ready)

        store.draft = "B 自己的未发送草稿"
        _ = try await gateway.request(method: "fixture.fail_submit")
        await sendA.value

        XCTAssertEqual(store.activeSessionID, "live-stored-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])
        XCTAssertEqual(store.draft, "B 自己的未发送草稿")
        XCTAssertNil(store.operationError)
        XCTAssertFalse(store.isStreaming)
        XCTAssertEqual(store.workspacePhase, .ready)

        for method in [
            "fixture.emit_session_start",
            "fixture.emit_session_error",
            "fixture.emit_session_complete",
        ] {
            _ = try await gateway.request(
                method: method,
                params: .object(["session_id": .string(sessionA)])
            )
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(store.activeSessionID, "live-stored-b")
            XCTAssertEqual(store.messages.map(\.text), ["B history"])
            XCTAssertEqual(store.draft, "B 自己的未发送草稿")
            XCTAssertNil(store.operationError)
            XCTAssertFalse(store.isStreaming)
            XCTAssertEqual(store.workspacePhase, .ready)
        }

        let calls = try await gateway.request(method: "fixture.calls")
        let submitted = calls.objectValue?["submitted_prompts"]?.arrayValue ?? []
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted.first?.objectValue?["session_id"]?.stringValue, sessionA)
        XCTAssertEqual(submitted.first?.objectValue?["text"]?.stringValue, "只属于 A 的文本")

        _ = try await gateway.request(method: "fixture.delay_next_submit")
        store.draft = "B 失败后应恢复的文本"
        let sendB = Task { await store.send() }
        let submitBBecamePending = await waitForFixtureSubmit(gateway)
        XCTAssertTrue(submitBBecamePending)
        _ = try await gateway.request(method: "fixture.fail_submit")
        await sendB.value

        XCTAssertEqual(store.activeSessionID, "live-stored-b")
        XCTAssertEqual(store.draft, "B 失败后应恢复的文本")
        XCTAssertEqual(store.operationError, "受控 submit 失败")
        XCTAssertFalse(store.isStreaming)
        XCTAssertEqual(store.workspacePhase, .failed("受控 submit 失败"))
        store.disconnect()
    }

    @MainActor
    func testControlledWebSocketDisconnectDuringHandshakeStaysDisconnected() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              var components = URLComponents(string: rawURL)
        else {
            throw XCTSkip("设置 HERMES_APPLE_PROMPT_FIXTURE_URL 后运行连接生命周期 E2E")
        }
        components.queryItems = [URLQueryItem(name: "delay_open", value: "1")]
        let delayedURL = try XCTUnwrap(components.url)
        let store = HermesChatStore(
            source: "connection-lifecycle-fixture",
            gateway: HermesGateway(clientID: "connection-lifecycle-fixture")
        )
        store.serverText = delayedURL.absoluteString

        let connectTask = Task { await store.connect() }
        let handshakePending = await waitForFixtureOpen(rawURL)
        XCTAssertTrue(handshakePending)
        store.disconnect()
        _ = try await fixtureGET(rawURL, path: "/fixture/release_open")
        await connectTask.value

        XCTAssertEqual(store.state, .disconnected)
        XCTAssertEqual(store.workspacePhase, .disconnected)
        XCTAssertFalse(store.isStreaming)
    }

    @MainActor
    func testControlledWebSocketLateDelegateCallbacksCannotFailCurrentConnection() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              let serverURL = URL(string: rawURL)
        else {
            throw XCTSkip("设置 HERMES_APPLE_PROMPT_FIXTURE_URL 后运行旧 WebSocket 回调 E2E")
        }
        let gateway = HermesGateway(clientID: "stale-delegate-fixture")
        try await gateway.connect(serverURL: serverURL, token: nil)
        XCTAssertEqual(gateway.state, .ready)

        let oldSession = URLSession(configuration: .ephemeral)
        let oldSocket = oldSession.webSocketTask(
            with: try XCTUnwrap(GatewayURL.websocketURL(serverURL: serverURL))
        )
        gateway.urlSession(
            oldSession,
            task: oldSocket,
            didCompleteWithError: GatewayError(code: 5090, message: "旧 task 迟到失败")
        )
        await Task.yield()
        XCTAssertEqual(gateway.state, .ready)

        gateway.urlSession(
            oldSession,
            webSocketTask: oldSocket,
            didCloseWith: .abnormalClosure,
            reason: nil
        )
        XCTAssertEqual(gateway.state, .ready)
        oldSession.invalidateAndCancel()
        gateway.disconnect()
    }

    @MainActor
    func testOutOfOrderSessionListsAndDisconnectIgnoreStaleResults() async {
        let requester = ReentrantSessionListRequester()
        let store = HermesChatStore(
            source: "session-list-generation",
            gateway: HermesGateway(clientID: "session-list-generation"),
            gatewayRequester: requester
        )
        requester.beforeNextListResult = { await store.refreshSessions() }
        await store.refreshSessions()

        XCTAssertEqual(store.sessions.map(\.id), ["stored-new"])
        XCTAssertEqual(store.sessions.map(\.title), ["新列表"])
        XCTAssertNil(store.operationError)

        requester.beforeNextListResult = { store.disconnect() }
        requester.nextFailureMessage = "旧列表迟到失败"
        await store.refreshSessions()

        XCTAssertEqual(store.sessions.map(\.id), ["stored-new"])
        XCTAssertNil(store.operationError)
        XCTAssertEqual(store.state, .disconnected)
        XCTAssertEqual(store.workspacePhase, .disconnected)
    }

    @MainActor
    func testLateStopSuccessAndFailureCannotRewriteLaterSelectedSession() async {
        let requester = SuspendingSessionActionRequester()
        let store = HermesChatStore(
            source: "session-action-stop",
            gateway: HermesGateway(clientID: "session-action-stop"),
            gatewayRequester: requester
        )
        await store.createSession()
        store.applyGatewayEvent(
            GatewayEvent(
                type: "message.start",
                sessionID: "action-live-a",
                payload: .object(["id": .string("a-stream")])
            )
        )
        XCTAssertTrue(store.isStreaming)

        requester.beforeInterruptResult = { await store.selectSession("stored-b") }
        requester.interruptStatus = "interrupted"
        requester.interruptFailureMessage = nil
        await store.stop()
        let sessionBMessages = store.messages
        XCTAssertEqual(store.activeSessionID, "action-live-b")
        XCTAssertEqual(store.messages, sessionBMessages)
        XCTAssertEqual(store.workspacePhase, .ready)
        XCTAssertFalse(store.isStreaming)
        XCTAssertNil(store.operationError)

        store.applyGatewayEvent(
            GatewayEvent(
                type: "message.start",
                sessionID: "action-live-b",
                payload: .object(["id": .string("b-stream")])
            )
        )
        requester.beforeInterruptResult = { await store.selectSession("stored-c") }
        requester.interruptFailureMessage = "A 的迟到 Stop 失败"
        await store.stop()
        let sessionCMessages = store.messages
        XCTAssertEqual(store.activeSessionID, "action-live-c")
        XCTAssertEqual(store.messages, sessionCMessages)
        XCTAssertEqual(store.workspacePhase, .ready)
        XCTAssertFalse(store.isStreaming)
        XCTAssertNil(store.operationError)
    }

    @MainActor
    func testLatePromptResponseFailureCannotPolluteLaterSessionOrRevivePrompt() async {
        let requester = SuspendingSessionActionRequester()
        let store = HermesChatStore(
            source: "session-action-prompt",
            gateway: HermesGateway(clientID: "session-action-prompt"),
            gatewayRequester: requester
        )
        await store.createSession()
        store.applyGatewayEvent(
            GatewayEvent(
                type: "secret.request",
                sessionID: "action-live-a",
                payload: .object([
                    "request_id": .string("action-secret-a"),
                    "prompt": .string("输入 A 的敏感内容"),
                ])
            )
        )
        let promptA = store.pendingApproval!
        requester.beforePromptResponseResult = { await store.selectSession("stored-b") }
        requester.promptResponseFailureMessage = "A 的迟到 Prompt 失败"
        await store.respond(to: promptA, accepted: true, value: "temporary")
        let sessionBMessages = store.messages
        XCTAssertEqual(store.activeSessionID, "action-live-b")
        XCTAssertEqual(store.messages, sessionBMessages)
        XCTAssertNil(store.pendingApproval)
        XCTAssertNil(store.operationError)
        XCTAssertEqual(store.workspacePhase, .ready)
    }

    @MainActor
    func testLateProviderRetrySuccessAndFailureCannotMutateLaterSession() async throws {
        let requester = SuspendingSessionActionRequester()
        let service = FakeConfigurationService()
        let gateway = HermesGateway(clientID: "session-action-retry")
        let store = HermesChatStore(
            source: "session-action-retry",
            gateway: gateway,
            gatewayRequester: requester,
            makeConfigurationService: { _, _ in service }
        )
        store.prepareConfigurationService(
            serverURL: URL(string: "http://127.0.0.1:9127")!,
            token: nil
        )
        await store.createSession()
        gateway.onEvent?(
            GatewayEvent(
                type: "error",
                sessionID: "action-live-a",
                payload: .object(["message": .string("No inference provider configured")])
            )
        )
        await Task.yield()
        _ = await store.selectMainModel(provider: "openai", model: "gpt-test")
        XCTAssertEqual(store.workspacePhase, .providerConfigurationSavedAwaitingRetry)

        var sessionBMessages: [ChatMessage] = []
        requester.beforeRetryResult = {
            await store.selectSession("stored-b")
            sessionBMessages = store.messages
        }
        requester.retryMessage = "只属于 A 的重试消息"
        requester.retryFailureMessage = nil
        await store.retryProviderRequest()

        XCTAssertEqual(store.activeSessionID, "action-live-b")
        XCTAssertEqual(store.messages, sessionBMessages)
        XCTAssertEqual(store.workspacePhase, .ready)
        XCTAssertNil(store.providerSetupError)
        XCTAssertTrue(requester.submittedPrompts.isEmpty)

        gateway.onEvent?(
            GatewayEvent(
                type: "error",
                sessionID: "action-live-b",
                payload: .object(["message": .string("No inference provider configured")])
            )
        )
        await Task.yield()
        _ = await store.selectMainModel(provider: "openai", model: "gpt-test")
        var sessionCMessages: [ChatMessage] = []
        requester.beforeRetryResult = {
            await store.selectSession("stored-c")
            sessionCMessages = store.messages
        }
        requester.retryFailureMessage = "B 的迟到 Retry 失败"
        await store.retryProviderRequest()

        XCTAssertEqual(store.activeSessionID, "action-live-c")
        XCTAssertEqual(store.messages, sessionCMessages)
        XCTAssertEqual(store.workspacePhase, .ready)
        XCTAssertNil(store.providerSetupError)
        XCTAssertTrue(requester.submittedPrompts.isEmpty)
    }

    @MainActor
    func testLateSuccessfulPromptResponseCannotClearANewerPromptOrRewriteATerminalPhase() async {
        let requester = SuspendingPromptRequester()
        let store = HermesChatStore(
            source: "prompt-race-test",
            gateway: HermesGateway(clientID: "prompt-race-test"),
            gatewayRequester: requester
        )
        await store.createSession()

        func secret(_ id: String) -> GatewayEvent {
            GatewayEvent(
                type: "secret.request",
                sessionID: "race-live",
                payload: .object([
                    "request_id": .string(id),
                    "prompt": .string("输入 \(id)"),
                ])
            )
        }

        store.applyGatewayEvent(secret("request-a"))
        let requestA = store.pendingApproval!
        let responseA = Task { await store.respond(to: requestA, accepted: true, value: "a") }
        await requester.waitUntilSuspended()
        store.applyGatewayEvent(secret("request-b"))
        requester.completePromptResponse()
        await responseA.value

        XCTAssertEqual(store.pendingApproval?.id, "request-b")
        XCTAssertEqual(store.workspacePhase, .awaitingInput)

        let requestB = store.pendingApproval!
        let responseB = Task { await store.respond(to: requestB, accepted: true, value: "b") }
        await requester.waitUntilSuspended()
        store.applyGatewayEvent(
            GatewayEvent(type: "message.complete", sessionID: "race-live", payload: nil)
        )
        XCTAssertNil(store.pendingApproval)
        XCTAssertEqual(store.workspacePhase, .ready)
        requester.completePromptResponse()
        await responseB.value

        XCTAssertNil(store.pendingApproval)
        XCTAssertEqual(store.workspacePhase, .ready)

        store.applyGatewayEvent(secret("request-c"))
        let requestC = store.pendingApproval!
        let responseC = Task { await store.respond(to: requestC, accepted: true, value: "c") }
        await requester.waitUntilSuspended()
        requester.completePromptResponse()
        await responseC.value

        XCTAssertNil(store.pendingApproval)
        XCTAssertEqual(store.workspacePhase, .streaming)
    }

    @MainActor
    func testOutOfOrderSessionResumeKeepsLatestChoiceAndClosesStaleLiveSession() async {
        let requester = OutOfOrderSessionRequester()
        let store = HermesChatStore(
            source: "session-order-test",
            gateway: HermesGateway(clientID: "session-order-test"),
            gatewayRequester: requester
        )
        await store.createSession()
        XCTAssertEqual(store.activeSessionID, "original-live")

        let resumeA = Task { await store.selectSession("stored-a") }
        await requester.waitUntilResumeIsPending("stored-a")
        let resumeB = Task { await store.selectSession("stored-b") }
        await requester.waitUntilResumeIsPending("stored-b")

        requester.completeResume(
            storedID: "stored-b",
            liveID: "live-b",
            message: "B history"
        )
        _ = await resumeB.value
        XCTAssertEqual(store.activeSessionID, "live-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])

        requester.completeResume(
            storedID: "stored-a",
            liveID: "live-a",
            message: "A stale history"
        )
        _ = await resumeA.value
        XCTAssertEqual(store.activeSessionID, "live-b")
        XCTAssertEqual(store.activeStoredSessionID, "stored-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])
        XCTAssertEqual(requester.closedLiveSessionIDs, ["live-a"])

        let resumeC = Task { await store.selectSession("stored-c") }
        await requester.waitUntilResumeIsPending("stored-c")
        let resumeD = Task { await store.selectSession("stored-d") }
        await requester.waitUntilResumeIsPending("stored-d")
        requester.failResume(storedID: "stored-d", message: "D failed")
        _ = await resumeD.value
        XCTAssertEqual(store.activeSessionID, "live-b")
        XCTAssertEqual(store.operationError, "D failed")

        requester.completeResume(
            storedID: "stored-c",
            liveID: "live-c",
            message: "C stale history"
        )
        _ = await resumeC.value
        XCTAssertEqual(store.activeSessionID, "live-b")
        XCTAssertEqual(store.messages.map(\.text), ["B history"])
        XCTAssertEqual(requester.closedLiveSessionIDs, ["live-a", "live-c"])
        XCTAssertEqual(store.operationError, "D failed")
    }

    @MainActor
    private func waitForPrompt(
        _ store: HermesChatStore,
        present: Bool,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (store.pendingApproval != nil) == present { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (store.pendingApproval != nil) == present
    }

    @MainActor
    private func waitForFixtureCreate(
        _ gateway: HermesGateway,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await gateway.request(method: "fixture.create_pending"),
               result.objectValue?["pending"]?.boolValue == true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @MainActor
    private func waitForFixtureSubmit(
        _ gateway: HermesGateway,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await gateway.request(method: "fixture.submit_pending"),
               result.objectValue?["pending"]?.boolValue == true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @MainActor
    private func waitForFixtureOpen(
        _ rawURL: String,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = try? await fixtureGET(rawURL, path: "/fixture/open_pending"),
               result["pending"] as? Bool == true
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @MainActor
    private func fixtureGET(_ rawURL: String, path: String) async throws -> [String: Any] {
        guard var components = URLComponents(string: rawURL) else {
            throw GatewayError(code: nil, message: "夹具 URL 无效")
        }
        components.path = path
        components.query = nil
        let url = try XCTUnwrap(components.url)
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeClient(
        baseURL: String = "http://127.0.0.1:9127",
        profile: String? = nil
    ) -> HermesConfigurationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationURLProtocol.self]
        return HermesConfigurationClient(
            serverURL: URL(string: baseURL)!,
            token: "test-token",
            profile: profile,
            session: URLSession(configuration: configuration)
        )
    }

    private static func response(
        _ request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? HermesConfigurationError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func retrySessionResult() -> JSONValue {
        .object([
            "session_id": .string("retry-live-session"),
            "stored_session_id": .string("retry-stored-session"),
            "messages": .array([
                .object([
                    "id": .string("older-assistant"),
                    "role": .string("assistant"),
                    "content": .string("已保留的更早上下文"),
                ]),
                .object([
                    "id": .string("failed-user"),
                    "role": .string("user"),
                    "content": .string("请继续上一项任务"),
                ]),
                .object([
                    "id": .string("failed-assistant"),
                    "role": .string("assistant"),
                    "content": .string("旧失败响应"),
                ]),
            ]),
        ])
    }
}

@MainActor
private final class FakeGatewayRequester: HermesGatewayRequesting {
    struct Call {
        let method: String
        let params: JSONValue?
    }

    var handler: ((String, JSONValue?) throws -> JSONValue)?
    private(set) var calls: [Call] = []

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        guard let handler else {
            throw GatewayError(code: nil, message: "没有为 \(method) 配置测试响应")
        }
        return try handler(method, params)
    }
}

@MainActor
private final class SuspendingPromptRequester: HermesGatewayRequesting {
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private(set) var isPromptResponseSuspended = false

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "session.create":
            return .object([
                "session_id": .string("race-live"),
                "stored_session_id": .string("race-stored"),
                "messages": .array([]),
            ])
        case "secret.respond":
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                isPromptResponseSuspended = true
            }
        default:
            throw GatewayError(code: nil, message: "未处理方法 \(method)")
        }
    }

    func waitUntilSuspended() async {
        while !isPromptResponseSuspended { await Task.yield() }
    }

    func completePromptResponse() {
        let suspended = continuation
        continuation = nil
        isPromptResponseSuspended = false
        suspended?.resume(returning: .object(["status": .string("ok")]))
    }
}

@MainActor
private final class SuspendingSessionActionRequester: HermesGatewayRequesting {
    var beforeInterruptResult: (() async -> Void)?
    var interruptStatus = "interrupted"
    var interruptFailureMessage: String?
    var beforePromptResponseResult: (() async -> Void)?
    var promptResponseFailureMessage: String?
    var beforeRetryResult: (() async -> Void)?
    var retryMessage = "retry message"
    var retryFailureMessage: String?
    private(set) var submittedPrompts: [(sessionID: String, text: String)] = []

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "session.create":
            return .object([
                "session_id": .string("action-live-a"),
                "stored_session_id": .string("action-stored-a"),
                "messages": .array([
                    .object([
                        "id": .string("a-history"),
                        "role": .string("assistant"),
                        "content": .string("A history"),
                    ]),
                ]),
            ])
        case "session.resume":
            let storedID = params?.objectValue?["session_id"]?.stringValue ?? ""
            if storedID == "stored-b" {
                return Self.resumeResult(
                    liveID: "action-live-b",
                    storedID: storedID,
                    messages: [
                        ("b-early", "assistant", "B earlier context"),
                        ("b-user", "user", "B user message"),
                        ("b-answer", "assistant", "B answer"),
                    ]
                )
            }
            return Self.resumeResult(
                liveID: "action-live-c",
                storedID: storedID,
                messages: [("c-history", "assistant", "C history")]
            )
        case "session.interrupt":
            let action = beforeInterruptResult
            beforeInterruptResult = nil
            await action?()
            if let interruptFailureMessage {
                throw GatewayError(code: 5008, message: interruptFailureMessage)
            }
            return .object(["status": .string(interruptStatus)])
        case "secret.respond":
            let action = beforePromptResponseResult
            beforePromptResponseResult = nil
            await action?()
            if let promptResponseFailureMessage {
                throw GatewayError(code: 5009, message: promptResponseFailureMessage)
            }
            return .object(["status": .string("ok")])
        case "slash.exec":
            let action = beforeRetryResult
            beforeRetryResult = nil
            await action?()
            if let retryFailureMessage {
                throw GatewayError(code: 5010, message: retryFailureMessage)
            }
            return .object([
                "type": .string("send"),
                "message": .string(retryMessage),
            ])
        case "prompt.submit":
            submittedPrompts.append(
                (
                    params?.objectValue?["session_id"]?.stringValue ?? "",
                    params?.objectValue?["text"]?.stringValue ?? ""
                )
            )
            return .object(["accepted": .bool(true)])
        default:
            throw GatewayError(code: nil, message: "未处理方法 \(method)")
        }
    }

    private static func resumeResult(
        liveID: String,
        storedID: String,
        messages: [(id: String, role: String, content: String)]
    ) -> JSONValue {
        .object([
            "session_id": .string(liveID),
            "resumed": .string(storedID),
            "messages": .array(
                messages.map { message in
                    .object([
                        "id": .string(message.id),
                        "role": .string(message.role),
                        "content": .string(message.content),
                    ])
                }
            ),
        ])
    }
}

@MainActor
private final class ReentrantSessionListRequester: HermesGatewayRequesting {
    var beforeNextListResult: (() async -> Void)?
    var nextFailureMessage: String?
    private var listCallCount = 0

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard method == "session.list" else {
            throw GatewayError(code: nil, message: "未处理方法 \(method)")
        }
        listCallCount += 1
        let call = listCallCount
        let action = beforeNextListResult
        beforeNextListResult = nil
        await action?()
        if let nextFailureMessage {
            self.nextFailureMessage = nil
            throw GatewayError(code: 5011, message: nextFailureMessage)
        }
        let isNewestNestedCall = call == 2
        return .object([
            "sessions": .array([
                .object([
                    "id": .string(isNewestNestedCall ? "stored-new" : "stored-old"),
                    "title": .string(isNewestNestedCall ? "新列表" : "旧列表"),
                    "preview": .string("preview"),
                ]),
            ]),
        ])
    }
}

@MainActor
private final class OutOfOrderSessionRequester: HermesGatewayRequesting {
    private var resumeContinuations: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private(set) var closedLiveSessionIDs: [String] = []

    func request(method: String, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case "session.create":
            return .object([
                "session_id": .string("original-live"),
                "stored_session_id": .string("original-stored"),
                "messages": .array([
                    .object([
                        "id": .string("original-message"),
                        "role": .string("assistant"),
                        "content": .string("Original history"),
                    ]),
                ]),
            ])
        case "session.resume":
            let storedID = params?.objectValue?["session_id"]?.stringValue ?? ""
            return try await withCheckedThrowingContinuation { continuation in
                resumeContinuations[storedID] = continuation
            }
        case "session.close":
            if let liveID = params?.objectValue?["session_id"]?.stringValue {
                closedLiveSessionIDs.append(liveID)
            }
            return .object(["closed": .bool(true)])
        default:
            throw GatewayError(code: nil, message: "未处理方法 \(method)")
        }
    }

    func waitUntilResumeIsPending(_ storedID: String) async {
        while resumeContinuations[storedID] == nil { await Task.yield() }
    }

    func completeResume(storedID: String, liveID: String, message: String) {
        let continuation = resumeContinuations.removeValue(forKey: storedID)
        continuation?.resume(
            returning: .object([
                "session_id": .string(liveID),
                "resumed": .string(storedID),
                "messages": .array([
                    .object([
                        "id": .string("\(liveID)-message"),
                        "role": .string("assistant"),
                        "content": .string(message),
                    ]),
                ]),
            ])
        )
    }

    func failResume(storedID: String, message: String) {
        let continuation = resumeContinuations.removeValue(forKey: storedID)
        continuation?.resume(throwing: GatewayError(code: 5000, message: message))
    }
}

private final class FakeConfigurationService: HermesConfigurationServing {
    private(set) var modelAssignmentCalls = 0

    func providerOptions(includeUnconfigured: Bool, refresh: Bool) async throws
        -> HermesProviderOptions
    {
        let data = Data(
            #"{"model":"gpt-test","provider":"openai","providers":[{"name":"OpenAI","slug":"openai","models":["gpt-test"],"authenticated":false}]}"#.utf8
        )
        return try JSONDecoder().decode(HermesProviderOptions.self, from: data)
    }

    func environment() async throws -> [String: HermesEnvironmentVariable] {
        let data = Data(
            #"{"OPENAI_API_KEY":{"is_set":false,"redacted_value":null,"description":"OpenAI","url":null,"category":"provider","is_password":true,"advanced":false,"provider":"openai","provider_label":"OpenAI"}}"#.utf8
        )
        return try JSONDecoder().decode([String: HermesEnvironmentVariable].self, from: data)
    }

    func validateCredential(key: String, value: String, apiKey: String?) async throws
        -> HermesCredentialValidation
    {
        try JSONDecoder().decode(
            HermesCredentialValidation.self,
            from: Data(#"{"ok":true,"reachable":true,"message":""}"#.utf8)
        )
    }

    func saveCredential(key: String, value: String) async throws {}

    func setMainModel(
        provider: String,
        model: String,
        confirmExpensiveModel: Bool,
        baseURL: String,
        apiKey: String
    ) async throws -> HermesModelAssignment {
        modelAssignmentCalls += 1
        return try JSONDecoder().decode(
            HermesModelAssignment.self,
            from: Data(#"{"ok":true,"provider":"openai","model":"gpt-test"}"#.utf8)
        )
    }
}

private final class ReentrantConfigurationService: HermesConfigurationServing {
    var suspendNextOptions = false
    var suspendNextValidation = false
    var suspendNextModelAssignment = false
    private var optionsCallCount = 0
    private var optionsContinuation: CheckedContinuation<HermesProviderOptions, Error>?
    private var validationContinuation: CheckedContinuation<HermesCredentialValidation, Error>?
    private var modelContinuation: CheckedContinuation<HermesModelAssignment, Error>?
    private(set) var savedCredentialCount = 0

    func providerOptions(includeUnconfigured: Bool, refresh: Bool) async throws
        -> HermesProviderOptions
    {
        optionsCallCount += 1
        let call = optionsCallCount
        if suspendNextOptions {
            suspendNextOptions = false
            return try await withCheckedThrowingContinuation { continuation in
                optionsContinuation = continuation
            }
        }
        let model = call == 1 ? "old-model" : "new-model"
        let provider = call == 1 ? "old-provider" : "new-provider"
        return try JSONDecoder().decode(
            HermesProviderOptions.self,
            from: Data(
                """
                {"model":"\(model)","provider":"\(provider)","providers":[{"name":"Provider","slug":"\(provider)","models":["\(model)"],"authenticated":true}]}
                """.utf8
            )
        )
    }

    func environment() async throws -> [String: HermesEnvironmentVariable] {
        try JSONDecoder().decode(
            [String: HermesEnvironmentVariable].self,
            from: Data(
                #"{"OPENAI_API_KEY":{"is_set":true,"redacted_value":"***","description":"OpenAI","url":null,"category":"provider","is_password":true,"advanced":false,"provider":"openai","provider_label":"OpenAI"}}"#.utf8
            )
        )
    }

    func validateCredential(key: String, value: String, apiKey: String?) async throws
        -> HermesCredentialValidation
    {
        if suspendNextValidation {
            suspendNextValidation = false
            return try await withCheckedThrowingContinuation { continuation in
                validationContinuation = continuation
            }
        }
        return try JSONDecoder().decode(
            HermesCredentialValidation.self,
            from: Data(#"{"ok":false,"reachable":true,"message":"旧验证失败","models":[]}"#.utf8)
        )
    }

    func saveCredential(key: String, value: String) async throws {
        savedCredentialCount += 1
    }

    func setMainModel(
        provider: String,
        model: String,
        confirmExpensiveModel: Bool,
        baseURL: String,
        apiKey: String
    ) async throws -> HermesModelAssignment {
        if suspendNextModelAssignment {
            suspendNextModelAssignment = false
            return try await withCheckedThrowingContinuation { continuation in
                modelContinuation = continuation
            }
        }
        return try JSONDecoder().decode(
            HermesModelAssignment.self,
            from: Data(
                """
                {"ok":true,"provider":"\(provider)","model":"\(model)"}
                """.utf8
            )
        )
    }

    func waitUntilOptionsPending(timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { self.optionsContinuation != nil }
    }

    func waitUntilValidationPending(timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { self.validationContinuation != nil }
    }

    func waitUntilModelAssignmentPending(timeout: TimeInterval = 2) async -> Bool {
        await waitUntil(timeout: timeout) { self.modelContinuation != nil }
    }

    func completeOptions(model: String, provider: String) {
        let continuation = optionsContinuation
        optionsContinuation = nil
        continuation?.resume(returning: try! Self.options(model: model, provider: provider))
    }

    func completeValidation(ok: Bool, message: String) {
        let continuation = validationContinuation
        validationContinuation = nil
        continuation?.resume(returning: try! JSONDecoder().decode(
            HermesCredentialValidation.self,
            from: Data(
                """
                {"ok":\(ok),"reachable":true,"message":"\(message)","models":[]}
                """.utf8
            )
        ))
    }

    func completeModelAssignment(provider: String, model: String) {
        let continuation = modelContinuation
        modelContinuation = nil
        continuation?.resume(returning: try! JSONDecoder().decode(
            HermesModelAssignment.self,
            from: Data(
                """
                {"ok":true,"provider":"\(provider)","model":"\(model)"}
                """.utf8
            )
        ))
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func options(model: String, provider: String) throws -> HermesProviderOptions {
        try JSONDecoder().decode(
            HermesProviderOptions.self,
            from: Data(
                """
                {"model":"\(model)","provider":"\(provider)","providers":[{"name":"Provider","slug":"\(provider)","models":["\(model)"],"authenticated":true}]}
                """.utf8
            )
        )
    }
}

private final class ConfigurationURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: HermesConfigurationError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
