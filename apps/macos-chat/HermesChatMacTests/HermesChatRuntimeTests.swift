import XCTest
import Combine
@testable import HermesChatMac

@MainActor
final class HermesChatRuntimeTests: XCTestCase {
    func testLoopbackEndpointSelectorReturnsEphemeralLocalHTTPURL() throws {
        let first = try HermesLoopbackEndpointSelector.availableURL()

        XCTAssertEqual(first.scheme, "http")
        XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertEqual(first.path, "/")
        XCTAssertNotNil(first.port)
        XCTAssertGreaterThan(first.port ?? 0, 0)
    }

    func testMissingExecutableFailsBeforeAllocatingPortOrStartingProcess() async {
        var endpointSelectionCount = 0
        let runtime = HermesChatRuntime(
            executableLocator: { _ in nil },
            endpointSelector: {
                endpointSelectionCount += 1
                return URL(string: "http://127.0.0.1:19127/")!
            },
            sharedBackendDiscoverer: { _ in nil }
        )

        await runtime.startLocal(preferredExecutablePath: "/missing/hermes")

        XCTAssertEqual(endpointSelectionCount, 0)
        XCTAssertEqual(runtime.state, .failed("未找到 Hermes 可执行文件"))
        XCTAssertTrue(runtime.statusDetail.contains("安装 Hermes"))
        XCTAssertFalse(runtime.processController.ownsRunningProcess)
        XCTAssertEqual(runtime.chat.state, .disconnected)
    }

    func testEndpointAllocationFailureIsVisibleAndDoesNotStartBackend() async {
        let runtime = HermesChatRuntime(
            executableLocator: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            endpointSelector: {
                throw HermesLoopbackEndpointError.invalidPort
            },
            sharedBackendDiscoverer: { _ in nil }
        )

        await runtime.startLocal()

        XCTAssertEqual(runtime.state, .failed("无法分配本地 Hermes 端口"))
        XCTAssertTrue(runtime.statusDetail.contains("无效"))
        XCTAssertFalse(runtime.processController.ownsRunningProcess)
        XCTAssertEqual(runtime.chat.state, .disconnected)
    }

    func testStopClearsRuntimeWithoutStoppingUnownedHermesProcesses() {
        let runtime = HermesChatRuntime()

        runtime.stop()

        XCTAssertEqual(runtime.state, .idle)
        XCTAssertEqual(runtime.statusDetail, "")
        XCTAssertFalse(runtime.processController.ownsRunningProcess)
        XCTAssertEqual(runtime.chat.state, .disconnected)
    }

    func testBackendProcessEvidenceUsesStableKeysWithoutSecretValue() throws {
        let secret = "temporary-secret-token"
        let evidence = HermesChatBackendProcessEvidence(
            schemaVersion: "1",
            backendMode: "serve",
            backendCapability: "serve_supported",
            ownedProcess: true,
            processID: 123,
            host: "127.0.0.1",
            port: 19127,
            arguments: ["serve", "--no-open", "--host", "127.0.0.1", "--port", "19127"],
            sessionTokenInArguments: false
        )

        let encoded = try JSONEncoder().encode(evidence)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["backend_mode"] as? String, "serve")
        XCTAssertEqual(object["backend_capability"] as? String, "serve_supported")
        XCTAssertEqual(object["owned_process"] as? Bool, true)
        XCTAssertEqual(object["session_token_in_arguments"] as? Bool, false)
        XCTAssertNil(object["session_token"])
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains(secret) ?? true)
    }

    func testUnexpectedOwnedBackendExitUpdatesRuntimeFailureState() async {
        let process = RuntimeTestBackendProcess()
        let chat = RuntimeTestChatConnection()
        let probe = RuntimeTestProbeSequence([
            HermesBackendProbeResult(
                reachable: false,
                statusCode: nil,
                version: nil,
                hermesHome: nil,
                authRequired: nil,
                description: "offline"
            ),
            HermesBackendProbeResult(
                reachable: true,
                statusCode: 200,
                version: "test",
                hermesHome: nil,
                authRequired: false,
                description: "ready"
            ),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in probe.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "runtime-test-token" },
            sleep: { _ in }
        )
        let runtime = HermesChatRuntime(
            chatConnection: chat,
            backendCoordinator: coordinator,
            executableLocator: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            endpointSelector: { URL(string: "http://127.0.0.1:19127/")! },
            sharedBackendDiscoverer: { _ in nil }
        )

        await runtime.startLocal()
        guard case .readyLocal = runtime.state else {
            return XCTFail("runtime 应先进入 readyLocal，当前为 \(runtime.state)")
        }

        process.crash(log: "controlled owned backend crash")
        for _ in 0..<20 {
            if case .failed = runtime.state { break }
            await Task.yield()
        }

        XCTAssertEqual(runtime.state, .failed("Hermes backend 进程意外退出"))
        XCTAssertTrue(runtime.statusDetail.contains("Hermes backend 进程意外退出"))
        XCTAssertTrue(runtime.statusDetail.contains("controlled owned backend crash"))
        XCTAssertEqual(chat.state, .disconnected)
    }

    func testLiveSharedGatewayIsPreferredBeforeExecutableLookupOrPortSelection() async {
        let process = RuntimeTestBackendProcess()
        let chat = RuntimeTestChatConnection()
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in XCTFail("共享连接不应启动 owned backend"); return .unreachableForRuntimeTest },
            capabilityCheck: { _ in XCTFail("共享连接不应探测 serve"); return .supported }
        )
        var executableLookupCount = 0
        var endpointSelectionCount = 0
        let descriptor = sharedDescriptor(home: "/tmp/hermes-shared-test")
        let runtime = HermesChatRuntime(
            chatConnection: chat,
            backendCoordinator: coordinator,
            executableLocator: { _ in
                executableLookupCount += 1
                return nil
            },
            endpointSelector: {
                endpointSelectionCount += 1
                return URL(string: "http://127.0.0.1:19127/")!
            },
            sharedBackendDiscoverer: { home in
                XCTAssertEqual(home, "/tmp/hermes-shared-test")
                return descriptor
            }
        )

        await runtime.startLocal(expectedHermesHome: "/tmp/hermes-shared-test")

        XCTAssertEqual(
            runtime.state,
            .readyShared(URL(string: descriptor.serverURL)!)
        )
        XCTAssertEqual(executableLookupCount, 0)
        XCTAssertEqual(endpointSelectionCount, 0)
        XCTAssertEqual(process.startCallCount, 0)
        XCTAssertFalse(process.ownsRunningProcess)
        XCTAssertEqual(chat.serverText, descriptor.serverURL)
        XCTAssertEqual(chat.tokenText, descriptor.sessionToken)
        XCTAssertEqual(chat.connectCallCount, 1)
        XCTAssertEqual(runtime.backendProcessEvidence().backendMode, "shared_gateway")

        runtime.stop()

        XCTAssertFalse(process.ownsRunningProcess)
        XCTAssertEqual(runtime.state, .idle)
        XCTAssertEqual(chat.state, .disconnected)
    }

    func testGatewayStartedAfterOwnedBackendMigratesAndResumesSession() async {
        let process = RuntimeTestBackendProcess()
        let chat = RuntimeTestChatConnection()
        let probe = RuntimeTestProbeSequence([
            .unreachableForRuntimeTest,
            HermesBackendProbeResult(
                reachable: true,
                statusCode: 200,
                version: "test",
                hermesHome: nil,
                authRequired: false,
                description: "ready"
            ),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in probe.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "owned-token" },
            sleep: { _ in }
        )
        let descriptor = sharedDescriptor(home: "/tmp/hermes-shared-test")
        let discoveries = RuntimeTestSharedDiscoverySequence([nil, descriptor])
        let runtime = HermesChatRuntime(
            chatConnection: chat,
            backendCoordinator: coordinator,
            executableLocator: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            endpointSelector: { URL(string: "http://127.0.0.1:19127/")! },
            sharedBackendDiscoverer: { _ in discoveries.next() }
        )

        await runtime.startLocal(expectedHermesHome: nil)
        XCTAssertEqual(runtime.state, .readyLocal(URL(string: "http://127.0.0.1:19127/")!))
        XCTAssertTrue(process.ownsRunningProcess)
        XCTAssertEqual(process.startCallCount, 1)

        await runtime.refreshSharedBackendIfAvailable()

        XCTAssertEqual(runtime.state, .readyShared(URL(string: descriptor.serverURL)!))
        XCTAssertFalse(process.ownsRunningProcess)
        XCTAssertEqual(process.startCallCount, 1)
        XCTAssertEqual(chat.connectCallCount, 2)
        XCTAssertEqual(chat.resumeCallCount, 1)
        XCTAssertEqual(chat.serverText, descriptor.serverURL)
    }

    func testFailedSharedHandoffKeepsOwnedProcessAndRestoresItsSession() async {
        let process = RuntimeTestBackendProcess()
        let chat = RuntimeTestChatConnection()
        chat.connectStates = [.ready, .failed("shared unavailable"), .ready]
        let probe = RuntimeTestProbeSequence([
            .unreachableForRuntimeTest,
            HermesBackendProbeResult(
                reachable: true,
                statusCode: 200,
                version: "test",
                hermesHome: nil,
                authRequired: false,
                description: "ready"
            ),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in probe.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "owned-token" },
            sleep: { _ in }
        )
        let descriptor = sharedDescriptor(home: "/tmp/hermes-shared-test")
        let discoveries = RuntimeTestSharedDiscoverySequence([nil, descriptor])
        let ownedURL = URL(string: "http://127.0.0.1:19127/")!
        let runtime = HermesChatRuntime(
            chatConnection: chat,
            backendCoordinator: coordinator,
            executableLocator: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            endpointSelector: { ownedURL },
            sharedBackendDiscoverer: { _ in discoveries.next() }
        )

        await runtime.startLocal()
        await runtime.refreshSharedBackendIfAvailable()

        XCTAssertEqual(runtime.state, .readyLocal(ownedURL))
        XCTAssertTrue(process.ownsRunningProcess)
        XCTAssertEqual(process.startCallCount, 1)
        XCTAssertEqual(chat.connectCallCount, 3)
        XCTAssertEqual(chat.resumeCallCount, 1)
        XCTAssertEqual(chat.serverText, ownedURL.absoluteString)
        XCTAssertEqual(chat.tokenText, "owned-token")

        await runtime.refreshSharedBackendIfAvailable()
        XCTAssertEqual(discoveries.callCount, 2, "失败后的退避期内不应立即重复交接")
    }

    func testStoppedSharedGatewayFallsBackToOwnedBackendAndResumesSession() async {
        let process = RuntimeTestBackendProcess()
        let chat = RuntimeTestChatConnection()
        let probe = RuntimeTestProbeSequence([
            .unreachableForRuntimeTest,
            HermesBackendProbeResult(
                reachable: true,
                statusCode: 200,
                version: "test",
                hermesHome: nil,
                authRequired: false,
                description: "ready"
            ),
        ])
        let coordinator = HermesBackendCoordinator(
            processController: process,
            chat: chat,
            probe: { _ in probe.next() },
            capabilityCheck: { _ in .supported },
            tokenGenerator: { "owned-token" },
            sleep: { _ in }
        )
        let descriptor = sharedDescriptor(home: "/tmp/hermes-shared-test")
        let discoveries = RuntimeTestSharedDiscoverySequence([descriptor, nil])
        let ownedURL = URL(string: "http://127.0.0.1:19127/")!
        let runtime = HermesChatRuntime(
            chatConnection: chat,
            backendCoordinator: coordinator,
            executableLocator: { _ in URL(fileURLWithPath: "/usr/bin/true") },
            endpointSelector: { ownedURL },
            sharedBackendDiscoverer: { _ in discoveries.next() }
        )

        await runtime.startLocal()
        XCTAssertEqual(runtime.state, .readyShared(URL(string: descriptor.serverURL)!))
        chat.disconnect()

        await runtime.refreshSharedBackendIfAvailable()

        XCTAssertEqual(runtime.state, .readyLocal(ownedURL))
        XCTAssertTrue(process.ownsRunningProcess)
        XCTAssertEqual(process.startCallCount, 1)
        XCTAssertEqual(chat.connectCallCount, 2)
        XCTAssertEqual(chat.resumeCallCount, 1)
        XCTAssertEqual(chat.serverText, ownedURL.absoluteString)
    }

    func testSharedDescriptorDiscoveryRejectsDifferentHermesHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "hermes-shared-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtimeDirectory = home.appending(path: "runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let descriptorURL = runtimeDirectory.appending(path: "shared-backend.json")
        let descriptor = sharedDescriptor(home: "/tmp/different-hermes-home")
        let data = try JSONEncoder().encode(descriptor)
        XCTAssertTrue(FileManager.default.createFile(atPath: descriptorURL.path, contents: data))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: descriptorURL.path
        )

        let found = await HermesSharedBackendDiscovery.findActive(
            hermesHome: home.path,
            probe: { _ in XCTFail("错误 profile 必须在网络探测前拒绝"); return .unreachableForRuntimeTest }
        )

        XCTAssertNil(found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptorURL.path))
    }

    func testSharedDescriptorDiscoveryValidatesLivePIDAndStartTime() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "hermes-shared-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtimeDirectory = home.appending(path: "runtime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let descriptorURL = runtimeDirectory.appending(path: "shared-backend.json")
        let pid = ProcessInfo.processInfo.processIdentifier
        let processStartTime = try XCTUnwrap(
            HermesSharedBackendDiscovery.processStartTime(pid: pid)
        )
        let descriptor = HermesSharedBackendDescriptor(
            schemaVersion: 1,
            owner: "gateway",
            pid: pid,
            processStartTime: processStartTime,
            serverURL: "http://127.0.0.1:19199/",
            sessionToken: "shared-runtime-token",
            hermesHome: home.path,
            instanceID: UUID().uuidString,
            startedAt: Date().timeIntervalSince1970
        )
        let data = try JSONEncoder().encode(descriptor)
        XCTAssertTrue(FileManager.default.createFile(atPath: descriptorURL.path, contents: data))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: descriptorURL.path
        )

        let found = await HermesSharedBackendDiscovery.findActive(
            hermesHome: home.path,
            probe: { _ in
                HermesBackendProbeResult(
                    reachable: true,
                    statusCode: 200,
                    version: "test",
                    hermesHome: home.path,
                    authRequired: false,
                    description: "ready"
                )
            }
        )

        XCTAssertEqual(found, descriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptorURL.path))
    }

    private func sharedDescriptor(home: String) -> HermesSharedBackendDescriptor {
        HermesSharedBackendDescriptor(
            schemaVersion: 1,
            owner: "gateway",
            pid: ProcessInfo.processInfo.processIdentifier,
            processStartTime: nil,
            serverURL: "http://127.0.0.1:19199/",
            sessionToken: "shared-runtime-token",
            hermesHome: home,
            instanceID: UUID().uuidString,
            startedAt: Date().timeIntervalSince1970
        )
    }
}

private extension HermesBackendProbeResult {
    static var unreachableForRuntimeTest: HermesBackendProbeResult {
        HermesBackendProbeResult(
            reachable: false,
            statusCode: nil,
            version: nil,
            hermesHome: nil,
            authRequired: nil,
            description: "offline"
        )
    }
}

@MainActor
private final class RuntimeTestBackendProcess: HermesBackendProcessManaging {
    private let ownership = CurrentValueSubject<Bool, Never>(false)
    private var log = ""
    var ownsRunningProcess: Bool { ownership.value }
    var ownershipPublisher: AnyPublisher<Bool, Never> { ownership.eraseToAnyPublisher() }
    private(set) var startCallCount = 0

    func startHeadlessBackend(
        executableURL: URL,
        serverURL: URL,
        sessionToken: String,
        legacyFallback: Bool,
        additionalEnvironment: [String: String]
    ) throws {
        startCallCount += 1
        ownership.send(true)
    }

    func stopOwnedProcess() {
        if ownership.value { ownership.send(false) }
    }
    func recentLog(maxBytes: Int) -> String { log }

    func crash(log: String) {
        self.log = log
        ownership.send(false)
    }
}

@MainActor
private final class RuntimeTestChatConnection: HermesChatConnecting {
    var serverText = ""
    var tokenText = ""
    private(set) var state: GatewayConnectionState = .disconnected
    var isStreaming = false
    var connectStates: [GatewayConnectionState] = [.ready]
    private(set) var connectCallCount = 0
    private(set) var resumeCallCount = 0

    func connect() async {
        connectCallCount += 1
        if connectStates.count > 1 {
            state = connectStates.removeFirst()
        } else {
            state = connectStates[0]
        }
    }
    func resumeActiveStoredSessionAfterReconnect() async -> Bool {
        resumeCallCount += 1
        return true
    }
    func disconnect() { state = .disconnected }
}

private final class RuntimeTestSharedDiscoverySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [HermesSharedBackendDescriptor?]
    private var calls = 0
    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    init(_ descriptors: [HermesSharedBackendDescriptor?]) {
        self.descriptors = descriptors
    }

    func next() -> HermesSharedBackendDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if descriptors.count > 1 { return descriptors.removeFirst() }
        return descriptors[0]
    }
}

private final class RuntimeTestProbeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HermesBackendProbeResult]

    init(_ results: [HermesBackendProbeResult]) {
        self.results = results
    }

    func next() -> HermesBackendProbeResult {
        lock.lock()
        defer { lock.unlock() }
        if results.count > 1 { return results.removeFirst() }
        return results[0]
    }
}
