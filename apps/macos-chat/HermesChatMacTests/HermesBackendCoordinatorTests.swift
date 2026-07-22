import Combine
import XCTest
@testable import HermesChatMac

@MainActor
final class HermesBackendCoordinatorTests: XCTestCase {
    func testServeCapabilityProbeTimesOutAndReapsHungProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hermes-serve-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "hermes")
        try "#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let started = Date()
        let result = await HermesServeCapabilityDetector.check(
            executableURL: executable,
            environment: HermesProcessEnvironment.base(),
            timeout: 0.2
        )

        guard case .checkFailed(let reason) = result else {
            return XCTFail("超时必须返回 checkFailed，实际为 \(result)")
        }
        XCTAssertTrue(reason.contains("超时"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTemporaryTokenIsURLSafeAndNotDeterministic() {
        let first = HermesTemporarySessionToken.make()
        let second = HermesTemporarySessionToken.make()
        XCTAssertGreaterThanOrEqual(first.count, 40)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains("+"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains("="))
    }

    func testCapabilityDetectorUsesServeHelpExitStatus() async {
        let supported = await HermesServeCapabilityDetector.check(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let failed = await HermesServeCapabilityDetector.check(
            executableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        XCTAssertEqual(supported, .supported)
        guard case .checkFailed = failed else {
            return XCTFail("普通非零退出不能被当作明确不支持：\(failed)")
        }
    }

    func testCapabilityDetectorOnlyFallsBackForExplicitUnknownServeCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hermes-serve-unsupported-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "hermes")
        try "#!/bin/sh\necho \"Error: No such command 'serve'.\" >&2\nexit 2\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let result = await HermesServeCapabilityDetector.check(executableURL: executable)

        XCTAssertEqual(result, .explicitlyUnsupported)
    }

    func testCoordinatorFallsBackToLegacyThenConnectsChatAfterStrictReadiness() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let results = ProbeSequence([
            .unreachable("预检连接拒绝"),
            .ready(version: "0.18.2", home: "/tmp/hermes-test-home"),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in await results.next() },
            capabilityCheck: { _ in .explicitlyUnsupported },
            tokenGenerator: { "temporary-token" },
            sleep: { _ in }
        )

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            expectedHermesHome: "/tmp/hermes-test-home",
            maximumAttempts: 2
        )

        XCTAssertEqual(process.startCalls.count, 1)
        XCTAssertTrue(process.startCalls[0].legacyFallback)
        XCTAssertEqual(process.startCalls[0].token, "temporary-token")
        XCTAssertEqual(chat.serverText, "http://127.0.0.1:19127")
        XCTAssertEqual(chat.connectedTokens, ["temporary-token"])
        XCTAssertEqual(
            coordinator.state,
            HermesBackendCoordinatorState.ready(version: "0.18.2")
        )
        XCTAssertEqual(coordinator.serveCapability, .serveUnavailable)
        XCTAssertTrue(process.ownsRunningProcess)
    }

    func testCoordinatorRefusesToTakeOverAnExistingBackend() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in .ready(version: "0.18.2", home: "/Users/example/.hermes") },
            capabilityCheck: { _ in .supported },
            sleep: { _ in }
        )

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!
        )

        XCTAssertTrue(process.startCalls.isEmpty)
        XCTAssertEqual(process.stopCallCount, 1)
        XCTAssertEqual(chat.connectCallCount, 0)
        guard case .failed(let message) = coordinator.state else {
            return XCTFail("预期端口占用失败")
        }
        XCTAssertTrue(message.contains("端口已被占用"))
    }

    func testCoordinatorReportsOwnedProcessCrashAndDisconnectsChat() async {
        let process = FakeBackendProcess()
        process.exitImmediatelyAfterStart = true
        process.log = "Address already in use"
        let chat = FakeChatConnection()
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in .unreachable("尚未就绪") },
            capabilityCheck: { _ in .supported },
            sleep: { _ in }
        )

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            maximumAttempts: 1
        )

        guard case .failed(let message) = coordinator.state else {
            return XCTFail("预期进程退出失败")
        }
        XCTAssertTrue(message.contains("退出"))
        XCTAssertEqual(coordinator.statusDetail, "Address already in use")
        XCTAssertGreaterThanOrEqual(chat.disconnectCallCount, 1)
        XCTAssertNil(coordinator.sessionToken)
    }

    func testCoordinatorResumesStoredSessionAfterUnexpectedReadyBackendExitAndRestart() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let results = ProbeSequence([
            .unreachable("首次预检"),
            .ready(version: "0.18.2", home: nil),
            .unreachable("恢复预检"),
            .ready(version: "0.18.2", home: nil),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in await results.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "temporary-token" },
            sleep: { _ in }
        )

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            maximumAttempts: 1
        )
        XCTAssertEqual(chat.resumeActiveStoredSessionCallCount, 0)

        process.crash()
        for _ in 0..<20 {
            if case .failed = coordinator.state { break }
            await Task.yield()
        }
        guard case .failed = coordinator.state else {
            return XCTFail("ready owned backend 意外退出后必须进入 failed")
        }

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19128")!,
            maximumAttempts: 1
        )

        XCTAssertEqual(chat.connectCallCount, 2)
        XCTAssertEqual(chat.resumeActiveStoredSessionCallCount, 1)
        XCTAssertEqual(coordinator.state, .ready(version: "0.18.2"))
    }

    func testStopOnlyUsesOwnedProcessControllerAndClearsInMemoryToken() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let results = ProbeSequence([
            .unreachable("预检"),
            .ready(version: "0.18.2", home: nil),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in await results.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "memory-only-token" },
            sleep: { _ in }
        )
        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            maximumAttempts: 1
        )

        coordinator.stop()

        XCTAssertEqual(coordinator.state, HermesBackendCoordinatorState.idle)
        XCTAssertEqual(coordinator.serveCapability, .unknown)
        XCTAssertNil(coordinator.sessionToken)
        XCTAssertFalse(process.ownsRunningProcess)
        XCTAssertEqual(process.globalStopCallCount, 0)
    }

    func testSuccessfulHandoffStopsOnlyOwnedProcessWithoutDisconnectingReplacement() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let results = ProbeSequence([
            .unreachable("预检"),
            .ready(version: "0.18.2", home: nil),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in await results.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "owned-token" },
            sleep: { _ in }
        )
        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            maximumAttempts: 1
        )
        let disconnectsBeforeHandoff = chat.disconnectCallCount

        coordinator.stopOwnedProcessAfterHandoff()

        XCTAssertFalse(process.ownsRunningProcess)
        XCTAssertEqual(process.stopCallCount, 2)
        XCTAssertEqual(chat.disconnectCallCount, disconnectsBeforeHandoff)
        XCTAssertNil(coordinator.sessionToken)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCoordinatorDoesNotUseLegacyFallbackWhenCapabilityCheckFails() async {
        let process = FakeBackendProcess()
        let chat = FakeChatConnection()
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in .unreachable("预检连接拒绝") },
            capabilityCheck: { _ in .checkFailed("Python 依赖导入超时") },
            tokenGenerator: { "must-not-be-used" },
            sleep: { _ in }
        )

        await coordinator.start(
            executableURL: URL(fileURLWithPath: "/usr/bin/hermes"),
            serverURL: URL(string: "http://127.0.0.1:19127")!
        )

        XCTAssertTrue(process.startCalls.isEmpty)
        XCTAssertEqual(chat.connectCallCount, 0)
        XCTAssertNil(coordinator.sessionToken)
        XCTAssertEqual(coordinator.serveCapability, .serveCheckFailed)
        XCTAssertEqual(coordinator.statusDetail, "Python 依赖导入超时")
        guard case .failed(let message) = coordinator.state else {
            return XCTFail("能力探测失败时必须安全失败")
        }
        XCTAssertTrue(message.contains("无法确认"))
    }

    func testRealOwnedBackendStartProbeGatewayConnectAndStop() async throws {
        let environment = ProcessInfo.processInfo.environment
        let explicitExecutablePath = environment["HERMES_MAC_OWNED_BACKEND_E2E_EXECUTABLE"]
        guard environment["HERMES_MAC_OWNED_BACKEND_E2E"] == "1"
            || explicitExecutablePath?.isEmpty == false
        else {
            throw XCTSkip("设置 HERMES_MAC_OWNED_BACKEND_E2E_EXECUTABLE 后运行真实 owned backend E2E")
        }
        let checkoutRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executablePath = explicitExecutablePath?.isEmpty == false
            ? explicitExecutablePath!
            : checkoutRoot.appending(path: ".venv/bin/hermes").path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return XCTFail("真实 E2E 找不到可执行 Hermes：\(executablePath)")
        }
        let port = Int(environment["HERMES_MAC_OWNED_BACKEND_E2E_PORT"] ?? "19131") ?? 19131
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appending(path: "hermes-mac-coordinator-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let emptyPlugins = home.appending(path: "empty-plugins", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: emptyPlugins, withIntermediateDirectories: true)
        XCTAssertTrue(
            fileManager.createFile(
                atPath: home.appending(path: ".no-bundled-skills").path,
                contents: Data([0x31])
            )
        )
        defer { try? fileManager.removeItem(at: home) }

        let processController = HermesBackendProcessController()
        let chat = HermesChatStore(
            source: "macos-owned-backend-e2e",
            gateway: HermesGateway(clientID: "mac-owned-e2e")
        )
        let coordinator = HermesBackendCoordinator(
            processController: processController,
            chat: chat
        )
        let serverURL = URL(string: "http://127.0.0.1:\(port)")!

        await coordinator.start(
            executableURL: URL(fileURLWithPath: executablePath),
            serverURL: serverURL,
            expectedHermesHome: home.path,
            additionalEnvironment: [
                "HERMES_HOME": home.path,
                "HERMES_BUNDLED_PLUGINS": emptyPlugins.path,
            ],
            maximumAttempts: 120
        )
        defer { coordinator.stop() }

        guard case .ready(let version) = coordinator.state else {
            return XCTFail("真实 owned backend 未就绪：\(coordinator.statusDetail)")
        }
        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(chat.state, .ready)
        XCTAssertEqual(coordinator.backendStatus?.hermesHome, home.path)
        XCTAssertTrue(processController.ownsRunningProcess)
        XCTAssertNotNil(processController.ownedProcessIdentifier)
        XCTAssertEqual(processController.ownedMode, .headlessBackend)

        coordinator.stop()
        XCTAssertEqual(coordinator.state, HermesBackendCoordinatorState.idle)
        XCTAssertEqual(chat.state, .disconnected)
        XCTAssertFalse(processController.ownsRunningProcess)
        XCTAssertNil(processController.ownedProcessIdentifier)
        XCTAssertNil(coordinator.sessionToken)
    }
}

private extension HermesBackendProbeResult {
    static func unreachable(_ description: String) -> HermesBackendProbeResult {
        HermesBackendProbeResult(
            reachable: false,
            statusCode: nil,
            version: nil,
            hermesHome: nil,
            authRequired: nil,
            description: description
        )
    }

    static func ready(version: String, home: String?) -> HermesBackendProbeResult {
        HermesBackendProbeResult(
            reachable: true,
            statusCode: 200,
            version: version,
            hermesHome: home,
            authRequired: false,
            description: "Hermes \(version) 已就绪"
        )
    }
}

private actor ProbeSequence {
    private var results: [HermesBackendProbeResult]

    init(_ results: [HermesBackendProbeResult]) {
        self.results = results
    }

    func next() -> HermesBackendProbeResult {
        if results.count > 1 { return results.removeFirst() }
        return results[0]
    }
}

@MainActor
private final class FakeBackendProcess: HermesBackendProcessManaging {
    struct StartCall {
        let legacyFallback: Bool
        let token: String
    }

    private let ownership = CurrentValueSubject<Bool, Never>(false)
    var ownsRunningProcess: Bool { ownership.value }
    var ownershipPublisher: AnyPublisher<Bool, Never> { ownership.eraseToAnyPublisher() }
    var startCalls: [StartCall] = []
    var stopCallCount = 0
    var globalStopCallCount = 0
    var exitImmediatelyAfterStart = false
    var log = ""

    func startHeadlessBackend(
        executableURL: URL,
        serverURL: URL,
        sessionToken: String,
        legacyFallback: Bool,
        additionalEnvironment: [String: String]
    ) throws {
        startCalls.append(StartCall(legacyFallback: legacyFallback, token: sessionToken))
        ownership.send(true)
        if exitImmediatelyAfterStart { ownership.send(false) }
    }

    func stopOwnedProcess() {
        stopCallCount += 1
        ownership.send(false)
    }

    func recentLog(maxBytes: Int) -> String { log }

    func crash() {
        ownership.send(false)
    }
}

@MainActor
private final class FakeChatConnection: HermesChatConnecting {
    var serverText = ""
    var tokenText = ""
    private(set) var state: GatewayConnectionState = .disconnected
    var isStreaming = false
    var connectCallCount = 0
    var disconnectCallCount = 0
    var resumeActiveStoredSessionCallCount = 0
    var connectedTokens: [String] = []

    func connect() async {
        connectCallCount += 1
        connectedTokens.append(tokenText)
        tokenText = ""
        state = .ready
    }

    func resumeActiveStoredSessionAfterReconnect() async -> Bool {
        resumeActiveStoredSessionCallCount += 1
        return true
    }

    func disconnect() {
        disconnectCallCount += 1
        state = .disconnected
    }
}
