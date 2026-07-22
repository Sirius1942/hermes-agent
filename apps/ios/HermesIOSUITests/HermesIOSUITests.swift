import XCTest

final class HermesIOSUITests: XCTestCase {
    private let serverURL = "http://localhost:9127"
    private let evidenceProxyURL = "http://localhost:9130"
    private let testToken = "test-mvp-token"

    func testDefaultLaunchShowsNativeChatAndConnectionSheet() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 10),
            "App 默认首屏不是原生 Chat 工作台"
        )
        XCTAssertTrue(app.scrollViews["ios.chat.transcript"].exists)
        XCTAssertTrue(app.textFields["ios.chat.composer"].exists)
        XCTAssertTrue(app.buttons["ios.chat.sessions"].exists)
        XCTAssertTrue(app.buttons["ios.chat.connection"].exists)
        XCTAssertTrue(app.buttons["ios.chat.advanced"].exists)
        attachEvidence(app, name: "iOS 默认原生 Chat 工作台")

        app.buttons["ios.chat.connection"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.connection.root"].waitForExistence(timeout: 5),
            "连接入口没有打开原生连接 Sheet"
        )
        XCTAssertTrue(app.textFields["ios.connection.url"].exists)
        XCTAssertTrue(app.secureTextFields["ios.connection.token"].exists)
        XCTAssertTrue(app.buttons["ios.connection.connect"].exists)
        XCTAssertTrue(app.buttons["ios.connection.cancel"].exists)
        attachEvidence(app, name: "iOS 原生连接与服务 Sheet")

        app.buttons["ios.connection.cancel"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 5),
            "取消连接后没有返回原 Chat 工作台"
        )
    }

    func testSessionsSheetPreservesChatAsDefaultWorkspace() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 10)
        )
        app.buttons["ios.chat.sessions"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.sessions.root"].waitForExistence(timeout: 5),
            "会话入口没有打开原生 Sessions Sheet"
        )
        XCTAssertTrue(app.buttons["ios.session.close"].exists)
        XCTAssertTrue(app.buttons["ios.session.new"].exists)
        attachEvidence(app, name: "iOS 原生会话列表 Sheet")

        app.buttons["ios.session.close"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 5),
            "关闭 Sessions 后没有返回 Chat 工作台"
        )
    }

    func testControlledSessionListResumesSameStoredSession() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true)

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)

        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "受控 Session 场景缺少新建动作")
        newSession.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "新建 Session 后没有返回 Chat")

        send(
            "视觉验证：保存这条本地受控消息并恢复同一 Session",
            app: app,
            composer: composer
        )
        let completedReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "工具活动和 Diff 已同步到原生工作台")
        ).firstMatch
        XCTAssertTrue(completedReply.waitForExistence(timeout: 10), "受控消息没有完整写入 Session")
        dismissKeyboard(in: app)

        app.buttons["ios.chat.sessions"].tap()
        let storedRow = app.buttons[EvidenceIdentifierForUITest.promptStoredRow]
        XCTAssertTrue(storedRow.waitForExistence(timeout: 5), "会话列表没有显示本次创建的持久 Session")
        XCTAssertTrue(storedRow.label.contains("本次受控恢复会话"))
        XCTAssertTrue(app.descendants(matching: .any)["ios.session.list"].exists)
        attachEvidence(app, name: "iOS 受控 Session 列表包含当前会话")

        storedRow.tap()
        let storedMarker = app.descendants(matching: .any)["ios.session.stored"]
        XCTAssertTrue(storedMarker.waitForExistence(timeout: 5), "恢复后缺少持久 Session 标记")
        let firstStoredMarker = storedMarker.label
        XCTAssertTrue(firstStoredMarker.contains(EvidenceIdentifierForUITest.promptStoredHash))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "保存这条本地受控消息")
            ).firstMatch.waitForExistence(timeout: 5),
            "恢复后没有显示 SessionDB 中的用户消息"
        )
        XCTAssertTrue(completedReply.waitForExistence(timeout: 5), "恢复后没有显示受控 assistant 历史")
        attachEvidence(app, name: "iOS 恢复后工作台与持久 Session")

        app.buttons["ios.chat.sessions"].tap()
        XCTAssertTrue(storedRow.waitForExistence(timeout: 5), "再次打开列表后持久 Session 消失")
        app.buttons["ios.session.close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 5))
        app.buttons["ios.chat.sessions"].tap()
        XCTAssertTrue(storedRow.waitForExistence(timeout: 5), "关闭并重开列表后无法再次选择同一 Session")
        storedRow.tap()
        XCTAssertTrue(storedMarker.waitForExistence(timeout: 5))
        XCTAssertEqual(storedMarker.label, firstStoredMarker, "第二次恢复改变了持久 Session 哈希")
        attachEvidence(app, name: "iOS 再次恢复同一持久 Session")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        XCTAssertEqual(fixtureState["state_db_configured"] as? Bool, true)
        let events = fixtureState["events"] as? [[String: Any]] ?? []
        let methods = events.compactMap { $0["method"] as? String }
        XCTAssertTrue(methods.contains("session.create"))
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session.list" }.count, 3)
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session.resume" }.count, 2)
    }

    func testControlledDisconnectAndResumePreservesSessionAndDraft() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true)

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)

        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "断线恢复场景缺少新建 Session 动作")
        newSession.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "新建 Session 后没有返回 Chat")

        send(
            "视觉验证：断线重连后保留同一 Session、历史和草稿",
            app: app,
            composer: composer
        )
        let completedReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "工具活动和 Diff 已同步到原生工作台")
        ).firstMatch
        XCTAssertTrue(completedReply.waitForExistence(timeout: 10), "断线前受控消息没有完成")
        dismissKeyboard(in: app)

        let activeMarker = app.descendants(matching: .any)["ios.session.active"]
        let storedMarker = app.descendants(matching: .any)["ios.session.stored"]
        XCTAssertTrue(activeMarker.waitForExistence(timeout: 5))
        XCTAssertTrue(storedMarker.waitForExistence(timeout: 5))
        let activeBefore = activeMarker.label
        let storedBefore = storedMarker.label

        let draft = "断线后继续保留的本地草稿"
        focusComposer(composer, context: "断线前草稿输入")
        composer.typeText(draft)
        dismissKeyboard(in: app)

        let disconnected = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/disconnect",
            method: "POST"
        )
        XCTAssertEqual(disconnected["disconnected"] as? Int, 1)

        let failedState = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "ios.chat.connection.state", "失败：")
        ).firstMatch
        XCTAssertTrue(failedState.waitForExistence(timeout: 10), "受控断线后没有显示原生失败状态")
        XCTAssertTrue(app.buttons["ios.connection.open"].waitForExistence(timeout: 5))
        XCTAssertEqual(activeMarker.label, activeBefore, "断线后改变了当前 live Session")
        XCTAssertEqual(storedMarker.label, storedBefore, "断线后改变了持久 Session")
        XCTAssertTrue(String(describing: composer.value).contains(draft), "断线后清空了本地草稿")
        XCTAssertTrue(completedReply.exists, "断线后清空了已完成历史")
        attachEvidence(app, name: "iOS 断线后保留 Session、历史与草稿")

        app.buttons["ios.connection.open"].tap()
        let retry = app.buttons["ios.connection.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "断线后没有原生重试入口")
        attachEvidence(app, name: "iOS 断线恢复入口与明确重试")
        retry.tap()

        let online = app.staticTexts["在线"]
        XCTAssertTrue(online.waitForExistence(timeout: 15), "明确重试后没有恢复在线")
        app.buttons["ios.connection.cancel"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "重连后没有返回 Chat")
        let activeChangeDeadline = Date().addingTimeInterval(5)
        while activeMarker.label == activeBefore && Date() < activeChangeDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(activeMarker.label, activeBefore, "重连后没有通过 resume 获得新的 live Session")
        XCTAssertEqual(storedMarker.label, storedBefore, "重连后改变了持久 Session")
        XCTAssertTrue(String(describing: composer.value).contains(draft), "重连后没有恢复本地草稿")
        XCTAssertTrue(completedReply.waitForExistence(timeout: 5), "重连后没有恢复既有历史")
        attachEvidence(app, name: "iOS 重连后恢复同一 Session 与草稿")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        XCTAssertEqual(fixtureState["forced_disconnect_count"] as? Int, 1)
        XCTAssertGreaterThanOrEqual(fixtureState["connection_count"] as? Int ?? 0, 2)
        XCTAssertEqual(fixtureState["connected_clients"] as? Int, 1)
        let events = fixtureState["events"] as? [[String: Any]] ?? []
        let methods = events.compactMap { $0["method"] as? String }
        XCTAssertTrue(methods.contains("session.create"))
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session.list" }.count, 2)
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session.resume" }.count, 1)
        XCTAssertTrue(methods.contains("prompt.submit"))
    }

    func testControlledPromptLifecycleApprovalClarifyAndSecret() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true)

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        newSession.tap()

        send(
            "视觉验证：进入工具、审批、澄清和安全输入生命周期",
            app: app,
            composer: composer
        )
        let toolSummary = app.buttons["ios.tools.summary"]
        XCTAssertTrue(toolSummary.waitForExistence(timeout: 10), "Prompt 生命周期前没有工具活动")
        XCTAssertTrue(
            waitForValueContaining("完成", element: toolSummary, timeout: 10),
            "工具活动没有进入完成状态"
        )
        dismissKeyboard(in: app)
        attachEvidence(app, name: "iOS 工具活动进入 Prompt 生命周期")

        let promptRoot = app.descendants(matching: .any)["ios.prompt.root"]
        let approval = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/approval?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(approval["delivered"] as? Int, 1)
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "approval.request 没有显示原生 Prompt")
        XCTAssertTrue(app.buttons["ios.prompt.approve"].exists)
        XCTAssertTrue(app.buttons["ios.prompt.reject"].exists)
        XCTAssertTrue(app.buttons["ios.prompt.cancel"].exists)
        attachEvidence(app, name: "iOS Approval 原生拒绝")
        app.buttons["ios.prompt.reject"].tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5))

        let clarify = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/clarify?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(clarify["delivered"] as? Int, 1)
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "clarify.request 没有显示原生 Prompt")
        let clarifyInput = app.textFields["ios.prompt.clarify"]
        XCTAssertTrue(clarifyInput.exists)
        let clarifyChoice = app.buttons["Chat 与工具活动"]
        XCTAssertTrue(clarifyChoice.exists)
        clarifyChoice.tap()
        attachEvidence(app, name: "iOS Clarify 选项与输入")
        app.buttons["ios.prompt.approve"].tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5))

        let secret = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/secret?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(secret["delivered"] as? Int, 1)
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "secret.request 没有显示原生 Prompt")
        let secretInput = app.secureTextFields["ios.prompt.secret"]
        XCTAssertTrue(secretInput.exists)
        attachEvidence(app, name: "iOS Secret 安全输入空值")
        secretInput.tap()
        secretInput.typeText("UITEST-ONLY-CONTROLLED")
        XCTAssertFalse(String(describing: secretInput.value).contains("UITEST-ONLY-CONTROLLED"))
        attachEvidence(app, name: "iOS Secret 安全输入已掩码")
        app.buttons["ios.prompt.approve"].tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5))

        let secretCancel = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/secret?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(secretCancel["delivered"] as? Int, 1)
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5))
        app.buttons["ios.prompt.cancel"].tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5), "secret 取消后 Prompt 没有收起")
        attachEvidence(app, name: "iOS Secret 取消安全收口")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        let responses = fixtureState["prompt_responses"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            responses.contains {
                $0["method"] as? String == "approval.respond"
                    && $0["choice"] as? String == "deny"
                    && $0["accepted"] as? Bool == false
            }
        )
        XCTAssertTrue(
            responses.contains {
                $0["method"] as? String == "clarify.respond"
                    && $0["accepted"] as? Bool == true
            }
        )
        let secretResponses = responses.filter { $0["method"] as? String == "secret.respond" }
        XCTAssertEqual(secretResponses.count, 2)
        XCTAssertTrue(secretResponses.contains { $0["accepted"] as? Bool == true })
        XCTAssertTrue(secretResponses.contains { $0["accepted"] as? Bool == false })
        XCTAssertFalse(String(describing: responses).contains("UITEST-ONLY-CONTROLLED"))
    }

    func testAccessibilityDynamicTypePromptRemainsUsable() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true)

        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        newSession.tap()

        send(
            "视觉验证：辅助功能与动态文字下保持 Prompt 可操作",
            app: app,
            composer: composer
        )
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@", "工具活动和 Diff 已同步到原生工作台")
            ).firstMatch.waitForExistence(timeout: 10),
            "辅助功能验收前受控消息没有完成"
        )
        dismissKeyboard(in: app)

        let secret = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/secret?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(secret["delivered"] as? Int, 1)

        let promptRoot = app.descendants(matching: .any)["ios.prompt.root"]
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "动态文字场景没有显示原生 Prompt")
        let secretInput = app.secureTextFields["ios.prompt.secret"]
        XCTAssertTrue(secretInput.waitForExistence(timeout: 5), "动态文字场景缺少 Secret 安全输入")
        secretInput.tap()
        secretInput.typeText("UITEST-ONLY-ACCESSIBILITY")
        XCTAssertFalse(
            String(describing: secretInput.value).contains("UITEST-ONLY-ACCESSIBILITY"),
            "SecureField 在 Accessibility 值中回显了输入内容"
        )
        XCTAssertFalse(
            app.debugDescription.contains("UITEST-ONLY-ACCESSIBILITY"),
            "Secret 输入进入 Accessibility 树"
        )
        dismissPromptKeyboard(in: app)

        try assertPromptAccessibility(on: app, orientation: "portrait")
        attachEvidence(app, name: "iOS 辅助功能动态文字 Prompt 竖屏")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "旋转横屏后 Prompt 消失")
        try assertPromptAccessibility(on: app, orientation: "landscape")
        attachEvidence(app, name: "iOS 辅助功能动态文字 Prompt 横屏")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "恢复竖屏后 Prompt 消失")
        let cancel = app.buttons["ios.prompt.cancel"]
        if !waitForHittable(cancel, timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(cancel, timeout: 5), "动态文字下无法遍历到取消动作")
        cancel.tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5), "取消后 Prompt 没有收起")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        let responses = fixtureState["prompt_responses"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            responses.contains {
                $0["method"] as? String == "secret.respond"
                    && $0["accepted"] as? Bool == false
            },
            "动态文字场景的 Secret 取消没有形成拒绝/空值响应"
        )
        XCTAssertFalse(
            String(describing: responses).contains("UITEST-ONLY-ACCESSIBILITY"),
            "受控 fixture 保存了辅助功能测试输入"
        )
    }

    func testConnectsToRealHermesAndRendersChatComposer() throws {
        let app = launchAndConnect(serverURL: serverURL, token: testToken)
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        XCTAssertTrue(composer.exists, "连接成功后没有进入真实 Chat 页面")
        XCTAssertTrue(app.buttons["ios.chat.send"].exists, "Chat 页面没有发送控件")
        XCTAssertTrue(app.buttons["ios.chat.sessions"].exists, "Chat 页面没有会话入口")
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].exists,
            "Chat 页面没有稳定根 Accessibility ID"
        )
        attachEvidence(app, name: "iOS 真实 Hermes Chat 页面")
    }

    func testRealHermesSendRendersUserMessage() throws {
        let app = launchAndConnect(serverURL: serverURL, token: testToken)
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        XCTAssertTrue(composer.exists, "发送测试前没有进入真实 Chat 页面")

        let message = "TestLoop 真实发送验证"
        focusComposer(composer, context: "真实发送")
        composer.typeText(message)
        let send = app.buttons["ios.chat.send"]
        XCTAssertTrue(send.isEnabled, "输入消息后发送按钮仍不可用")
        send.tap()

        let userMessage = messageElement(role: "user", in: app)
        XCTAssertTrue(userMessage.waitForExistence(timeout: 10), "真实 prompt.submit 后界面没有显示用户消息")
        XCTAssertTrue(userMessage.label.contains(message), "用户消息语义元素没有显示本次发送正文")
        let backendResult = messageElement(role: "assistant", in: app)
        XCTAssertTrue(
            backendResult.waitForExistence(timeout: 30),
            "真实 prompt.submit 后没有显示模型回复或后端错误"
        )
        if backendResult.label.contains("错误：") {
            dismissKeyboard(in: app)
            attachEvidence(app, name: "iOS 真实聊天被后端错误阻断")
            XCTFail("APPLE-UX-010 需要真实模型回复，不能把后端错误判为聊天成功：\(backendResult.label)")
            return
        }
        dismissKeyboard(in: app)
        attachEvidence(app, name: "iOS 真实发送及后端结果")
    }

    func testUnavailableHermesShowsVisibleConnectionError() throws {
        let app = launchAndConnect(serverURL: "http://127.0.0.1:1", token: "")
        let failure = visibleFailure(in: app)
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "不可达服务没有在屏幕上显示连接错误")
        XCTAssertFalse(failure.label.isEmpty)
        attachEvidence(app, name: "iOS Hermes 连接失败可见错误")
    }

    func testEvidenceProxyCapturesProviderRecoveryRun() throws {
        let app = launchAndConnect(serverURL: evidenceProxyURL, token: testToken)
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        XCTAssertTrue(composer.exists, "证据代理连接后没有进入真实 Chat 页面")

        let message = "TestLoop 同次真实证据验证"
        focusComposer(composer, context: "同次证据发送")
        composer.typeText(message)
        let send = app.buttons["ios.chat.send"]
        XCTAssertTrue(send.isEnabled, "证据代理用例输入消息后发送按钮不可用")
        send.tap()

        let userMessage = messageElement(role: "user", in: app)
        XCTAssertTrue(userMessage.waitForExistence(timeout: 10), "同次真实运行没有显示用户消息")
        XCTAssertTrue(userMessage.label.contains(message), "同次真实运行的用户消息正文不一致")
        let recovery = app.descendants(matching: .any)["ios.provider.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 30), "同次真实运行没有显示 Provider 恢复卡")
        dismissKeyboard(in: app)
        attachEvidence(app, name: "iOS 同次 provider 恢复、RPC 与 SessionDB 证据")
        XCTAssertTrue(
            app.staticTexts["尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。"].exists,
            "APPLE-UX-016 没有显示批准契约要求的中文服务未配置摘要"
        )
        XCTAssertTrue(
            app.buttons["ios.provider.configure"].exists,
            "APPLE-UX-016 没有提供 App 内配置服务主动作"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.provider.diagnostics"].exists,
            "APPLE-UX-016 没有提供默认折叠的原始诊断入口"
        )
    }

    func testControlledGatewayRendersToolsApprovalAndStopsSafely() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true, "受控 Gateway 没有重置为本次独立证据运行")

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)

        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5), "受控在线测试没有显示新建 Session 动作")
        newSession.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "新建 Session 后没有返回 Chat composer")

        send(
            "视觉验证：请展示在线聊天、工具活动和 Diff",
            app: app,
            composer: composer
        )
        let completedReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "工具活动和 Diff 已同步到原生工作台")
        ).firstMatch
        XCTAssertTrue(completedReply.waitForExistence(timeout: 10), "iOS 没有显示受控 Gateway 完整流式回复")

        dismissKeyboard(in: app)
        let toolSummary = app.buttons["ios.tools.summary"]
        XCTAssertTrue(toolSummary.waitForExistence(timeout: 5), "iOS Chat 没有显示工具活动摘要")
        XCTAssertTrue(toolSummary.label.contains("read_file"), "工具摘要没有显示真实工具名称")
        XCTAssertTrue(String(describing: toolSummary.value).contains("完成"), "工具摘要没有进入完成状态")
        XCTAssertTrue(String(describing: toolSummary.value).contains("验收条件已核对"), "工具摘要缺少完成结果")
        attachEvidence(app, name: "iOS 受控在线聊天与工具完成")

        XCTAssertTrue(waitForHittable(toolSummary, timeout: 5), "工具摘要虽然可见，但不能通过真实点击操作")
        toolSummary.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let sheetState = app.descendants(matching: .any)["ios.sheet.state"]
        XCTAssertTrue(
            waitForValueContaining("tools", element: sheetState, timeout: 3),
            "真实点击后没有把工作台 Sheet 状态切换为 tools；当前状态：\(sheetState.label)"
        )
        let toolsRoot = app.descendants(matching: .any)["ios.tools.root"]
        XCTAssertTrue(toolsRoot.waitForExistence(timeout: 5), "工具摘要没有打开原生工具 Sheet")
        XCTAssertTrue(app.staticTexts["read_file"].exists, "工具 Sheet 没有显示工具名称")
        XCTAssertTrue(app.staticTexts["验收条件已核对"].exists, "工具 Sheet 没有显示完成摘要")
        let diff = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Diff")
        ).firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 5), "工具 Sheet 没有显示 Diff 折叠入口")
        diff.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "+ iOS 在线 Chat")).firstMatch
                .waitForExistence(timeout: 5),
            "展开 Diff 后没有显示 iOS 变更内容"
        )
        attachEvidence(app, name: "iOS 原生工具与 Diff Sheet")
        app.buttons["ios.tools.close"].tap()

        let approvalResult = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/approval?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(approvalResult["delivered"] as? Int, 1, "受控 approval 没有送达唯一 iOS Chat 客户端")
        let promptRoot = app.descendants(matching: .any)["ios.prompt.root"]
        XCTAssertTrue(promptRoot.waitForExistence(timeout: 5), "iOS 没有显示原生审批 Sheet")
        XCTAssertTrue(app.buttons["ios.prompt.approve"].exists)
        XCTAssertTrue(app.buttons["ios.prompt.reject"].exists)
        XCTAssertTrue(app.buttons["ios.prompt.cancel"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "printf 'Hermes visual acceptance'")
            ).firstMatch.exists,
            "审批 Sheet 没有显示受控命令正文"
        )
        attachEvidence(app, name: "iOS 原生审批 Sheet")
        app.buttons["ios.prompt.reject"].tap()
        XCTAssertTrue(promptRoot.waitForNonExistence(timeout: 5), "拒绝审批后 Prompt Sheet 没有关闭")

        send(
            "视觉验证：停止生成并保持当前 Session",
            app: app,
            composer: composer
        )
        let stop = app.buttons["ios.chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "长流式期间没有显示 Stop 动作")
        XCTAssertTrue(toolSummary.waitForExistence(timeout: 5), "长流式期间没有显示工具运行状态")
        XCTAssertTrue(String(describing: toolSummary.value).contains("运行中"), "Stop 前工具状态不是运行中")
        dismissKeyboard(in: app)
        attachEvidence(app, name: "iOS 受控流式 Stop 前")
        stop.tap()

        let workspacePhase = app.staticTexts["ios.chat.workspace.phase"]
        XCTAssertTrue(
            waitForValueContaining("已停止", element: workspacePhase, timeout: 5),
            "Stop 完成后工作台没有进入已停止状态"
        )
        XCTAssertTrue(
            waitForValueContaining("已中断", element: toolSummary, timeout: 5),
            "Stop 完成后运行中的工具没有进入已中断状态"
        )
        attachEvidence(app, name: "iOS Stop 后工具已中断")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        let interrupted = fixtureState["interrupted_session_ids"] as? [String] ?? []
        XCTAssertTrue(interrupted.contains("prompt-live"), "受控 Gateway 没有收到 iOS session.interrupt")
        let events = fixtureState["events"] as? [[String: Any]] ?? []
        let eventMethods = Set(events.compactMap { $0["method"] as? String })
        for method in [
            "session.create",
            "prompt.submit",
            "message.start",
            "message.delta",
            "tool.start",
            "tool.progress",
            "tool.complete",
            "message.complete",
            "approval.request",
            "approval.respond",
            "session.interrupt",
        ] {
            XCTAssertTrue(eventMethods.contains(method), "受控 RPC 证据缺少 \(method)")
        }
    }

    func testControlledProviderErrorShowsRecoveryAndPreservesSession() throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["HERMES_APPLE_PROMPT_FIXTURE_URL"],
              !fixtureURL.isEmpty
        else {
            throw XCTSkip("未提供 HERMES_APPLE_PROMPT_FIXTURE_URL")
        }

        let reset = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/reset",
            method: "POST"
        )
        XCTAssertEqual(reset["reset"] as? Bool, true)

        let app = launchAndConnect(serverURL: fixtureURL, token: "")
        let composer = app.textFields["ios.chat.composer"]
        waitForChatOrFail(on: app, composer: composer)
        app.buttons["ios.chat.sessions"].tap()
        let newSession = app.buttons["ios.session.new"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        newSession.tap()

        let sessionMarker = app.descendants(matching: .any)["ios.session.active"]
        XCTAssertTrue(sessionMarker.waitForExistence(timeout: 5), "Provider 错误前缺少当前 Session 证据")
        let sessionBefore = sessionMarker.label
        XCTAssertFalse(sessionBefore.contains(EvidenceIdentifierForUITest.noneHash))

        let draft = "等待 Provider 恢复的本地草稿"
        focusComposer(composer, context: "Provider 恢复草稿输入")
        composer.typeText(draft)
        let emitted = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/emit/provider-error?session_id=prompt-live",
            method: "POST"
        )
        XCTAssertEqual(emitted["delivered"] as? Int, 1, "Provider 错误没有送达唯一 iOS Chat 客户端")

        let recovery = app.descendants(matching: .any)["ios.provider.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5), "Provider 错误没有显示原生恢复卡")
        XCTAssertTrue(
            app.staticTexts["尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。"].exists,
            "恢复卡缺少批准设计要求的中文摘要"
        )
        XCTAssertEqual(sessionMarker.label, sessionBefore, "Provider 错误改变了当前 Session")
        XCTAssertTrue(String(describing: composer.value).contains(draft), "Provider 错误清空了未发送草稿")
        XCTAssertTrue(app.buttons["ios.provider.configure"].exists)
        XCTAssertTrue(app.buttons["ios.provider.cancel"].exists)

        let diagnostics = app.descendants(matching: .any)["ios.provider.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5), "恢复卡缺少原始诊断入口")
        diagnostics.tap()
        XCTAssertTrue(
            app.staticTexts["No inference provider configured"].waitForExistence(timeout: 5),
            "展开诊断后没有显示脱敏的原始 Provider 错误"
        )
        dismissKeyboard(in: app)
        attachEvidence(app, name: "iOS Provider 恢复卡与原始诊断")

        app.buttons["ios.provider.cancel"].tap()
        XCTAssertTrue(recovery.waitForExistence(timeout: 3), "取消 Provider 恢复后没有保留配置要求")
        XCTAssertTrue(
            waitForValueContaining(
                "需要配置服务",
                element: app.staticTexts["ios.chat.workspace.phase"],
                timeout: 3
            ),
            "取消后工作台没有保持 configurationRequired"
        )
        XCTAssertEqual(sessionMarker.label, sessionBefore, "取消 Provider 恢复后改变了当前 Session")
        XCTAssertTrue(String(describing: composer.value).contains(draft), "取消 Provider 恢复后清空了草稿")

        app.buttons["ios.provider.configure"].tap()
        let providerRoot = app.descendants(matching: .any)["ios.provider.root"]
        XCTAssertTrue(
            providerRoot.waitForExistence(timeout: 5),
            "配置服务主动作没有打开原生 Provider Sheet"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["ios.provider.provider-picker"].waitForExistence(timeout: 5),
            "Provider Sheet 没有显示 Provider 选择器"
        )
        XCTAssertTrue(app.staticTexts["受控 Provider"].exists, "配置页没有加载受控 Provider")
        XCTAssertTrue(app.staticTexts["controlled-model"].exists, "配置页没有加载受控模型")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "HTTP 404")).firstMatch.exists,
            "受控配置 API 仍显示 HTTP 404"
        )
        let save = app.buttons["ios.provider.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "配置页缺少保存动作")
        XCTAssertTrue(save.isEnabled, "Provider 与模型加载后保存动作仍不可用")
        attachEvidence(app, name: "iOS Provider 配置选项已加载")
        save.tap()

        XCTAssertTrue(providerRoot.waitForNonExistence(timeout: 5), "保存 Provider 后配置 Sheet 没有关闭")
        XCTAssertTrue(
            app.buttons["ios.provider.retry"].waitForExistence(timeout: 5),
            "保存 Provider 后没有显示明确重试动作"
        )
        XCTAssertTrue(app.buttons["ios.provider.cancel"].exists)
        XCTAssertTrue(
            waitForValueContaining(
                "等待重试",
                element: app.staticTexts["ios.chat.workspace.phase"],
                timeout: 3
            ),
            "保存 Provider 后工作台没有进入等待明确重试状态"
        )
        XCTAssertEqual(sessionMarker.label, sessionBefore, "保存 Provider 后改变了当前 Session")
        XCTAssertTrue(String(describing: composer.value).contains(draft), "保存 Provider 后清空了草稿")
        attachEvidence(app, name: "iOS Provider 保存后等待明确重试")

        let fixtureState = try fixtureRequest(
            fixtureURL: fixtureURL,
            path: "/fixture/state",
            method: "GET"
        )
        XCTAssertEqual(
            (fixtureState["submitted_prompts"] as? [Any])?.count,
            0,
            "保存 Provider 后不应自动重发上一条消息"
        )
        let configurationCalls = fixtureState["configuration_calls"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            configurationCalls.contains { $0["path"] as? String == "/api/model/set" },
            "受控配置证据缺少 /api/model/set"
        )
    }

    private func launchAndConnect(serverURL: String, token: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-HermesUITestServerURL", serverURL]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["ios.chat.root"].waitForExistence(timeout: 10),
            "App 默认首屏不是 Chat 工作台"
        )
        let openConnection = app.buttons["ios.chat.connection"]
        XCTAssertTrue(openConnection.waitForExistence(timeout: 5), "Chat 首屏没有连接入口")
        openConnection.tap()

        let address = app.textFields["ios.connection.url"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), "连接表单没有显示")
        address.tap()
        address.typeText(serverURL)

        if !token.isEmpty {
            let tokenField = app.secureTextFields["ios.connection.token"]
            XCTAssertTrue(tokenField.waitForExistence(timeout: 5), "Token 输入框没有显示")
            tokenField.tap()
            tokenField.typeText(token)
        }

        let connect = app.buttons["ios.connection.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "连接按钮没有显示")
        connect.tap()
        return app
    }

    private func waitForChatOrFail(on app: XCUIApplication, composer: XCUIElement) {
        let failure = visibleFailure(in: app)
        let online = app.staticTexts["在线"]
        let deadline = Date().addingTimeInterval(20)
        while !online.exists && !failure.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if failure.exists {
            attachEvidence(app, name: "iOS Hermes 连接失败")
            XCTFail("屏幕显示 Hermes 连接错误：\(failure.label)")
        }
        XCTAssertTrue(online.exists, "Hermes 连接未进入在线状态")
        XCTAssertTrue(composer.exists, "连接后 Chat composer 不存在")
    }

    private func send(_ text: String, app: XCUIApplication, composer: XCUIElement) {
        focusComposer(composer, context: "发送消息")
        composer.typeText(text)
        let send = app.buttons["ios.chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "输入消息后没有显示发送动作")
        XCTAssertTrue(send.isEnabled, "输入消息后发送动作不可用")
        send.tap()
    }

    private func focusComposer(_ composer: XCUIElement, context: String) {
        XCTAssertTrue(
            waitForHittable(composer, timeout: 5),
            "\(context)前 Composer 尚未完成页面或 Sheet 转场，不能安全点击"
        )
        composer.tap()
    }

    private func waitForValueContaining(
        _ value: String,
        element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let rendered = "\(element.label) \(String(describing: element.value))"
            if element.exists && rendered.contains(value) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return "\(element.label) \(String(describing: element.value))".contains(value)
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && element.isHittable
    }

    private func assertPromptAccessibility(
        on app: XCUIApplication,
        orientation: String
    ) throws {
        let promptRoot = app.descendants(matching: .any)["ios.prompt.root"]
        let secretInput = app.secureTextFields["ios.prompt.secret"]
        XCTAssertTrue(promptRoot.exists, "\(orientation) Prompt 根节点不可达")
        XCTAssertTrue(secretInput.exists, "\(orientation) Secret 输入不可达")

        for identifier in ["ios.prompt.cancel", "ios.prompt.reject", "ios.prompt.approve"] {
            let action = app.buttons[identifier]
            var attempts = 0
            while !waitForHittable(action, timeout: 1) && attempts < 6 {
                app.collectionViews.firstMatch.swipeUp()
                attempts += 1
            }
            XCTAssertTrue(action.exists, "\(orientation) 缺少 \(identifier)")
            XCTAssertTrue(waitForHittable(action, timeout: 5), "\(orientation) 无法聚焦或操作 \(identifier)")
            XCTAssertFalse(action.label.isEmpty, "\(orientation) \(identifier) 只靠颜色表达状态")
            XCTAssertFalse(action.frame.isEmpty, "\(orientation) \(identifier) 没有可点击区域")
            XCTAssertGreaterThanOrEqual(action.frame.height, 44, "\(orientation) \(identifier) 点击区域不足 44pt")
        }

        let actions = [
            app.buttons["ios.prompt.cancel"],
            app.buttons["ios.prompt.reject"],
            app.buttons["ios.prompt.approve"],
        ]
        for index in actions.indices {
            for otherIndex in actions.indices where otherIndex > index {
                let overlap = actions[index].frame.intersection(actions[otherIndex].frame)
                XCTAssertFalse(
                    overlap.width > 1 && overlap.height > 1,
                    "\(orientation) Prompt 动作发生重叠：\(actions[index].identifier) / \(actions[otherIndex].identifier)"
                )
            }
        }

        XCTAssertGreaterThanOrEqual(secretInput.frame.height, 44, "\(orientation) Secret 输入点击区域不足 44pt")
        try app.performAccessibilityAudit(for: [.hitRegion, .trait])
    }

    private func fixtureRequest(
        fixtureURL: String,
        path: String,
        method: String
    ) throws -> [String: Any] {
        guard let url = URL(string: fixtureURL + path) else {
            XCTFail("受控 Gateway URL 无效：\(fixtureURL + path)")
            return [:]
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let completed = expectation(description: "受控 Gateway HTTP \(method) \(path)")
        var result: Result<[String: Any], Error>?
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { completed.fulfill() }
            if let error {
                result = .failure(error)
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data ?? Data())
                guard let payload = object as? [String: Any] else {
                    throw NSError(
                        domain: "HermesIOSUITests",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "夹具响应不是 JSON 对象"]
                    )
                }
                result = .success(payload)
            } catch {
                result = .failure(error)
            }
        }.resume()
        wait(for: [completed], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func visibleFailure(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "失败：")
        ).firstMatch
    }

    private func messageElement(role: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "message.\(role).")
        ).firstMatch
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let appDismiss = app.buttons["ios.chat.keyboard.dismiss"]
        if appDismiss.waitForExistence(timeout: 2) {
            appDismiss.tap()
        } else {
            let transcript = app.scrollViews["ios.chat.transcript"]
            if transcript.exists {
                transcript.swipeUp()
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while keyboard.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(keyboard.exists, "最终视觉证据截图前未能收起键盘")
    }

    private func dismissPromptKeyboard(in app: XCUIApplication) {
        guard app.keyboards.count > 0 else { return }
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.waitForExistence(timeout: 2) && returnKey.isHittable {
            returnKey.tap()
        } else {
            let navigationBar = app.navigationBars["Hermes 请求"]
            if navigationBar.waitForExistence(timeout: 2) {
                navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while app.keyboards.count > 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(app.keyboards.count, 0, "Prompt 最终视觉证据截图前未能收起键盘")
    }

    private func attachEvidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let accessibility = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        accessibility.name = "\(name)-可访问性树"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }
}

private enum EvidenceIdentifierForUITest {
    static let noneHash = "140bedbf9c3f6d56a9846d2ba7088798683f4da0c248231336e6a05679e4fdfe"
    static let promptStoredHash = "c46d660657c1e34954e8b4513da6db3c3e5bb29fb835d2a48e6c1f0882b876e4"
    static let promptStoredRow = "session.row.\(promptStoredHash)"
}
