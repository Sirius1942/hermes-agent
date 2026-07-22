import Combine
import Darwin
import Foundation

struct HermesBackendProbeResult: Equatable {
    let reachable: Bool
    let statusCode: Int?
    let version: String?
    let hermesHome: String?
    let authRequired: Bool?
    let description: String
}

enum HermesBackendURLBuilder {
    static func statusURL(for serverURL: URL) -> URL? {
        serverURL.appending(path: "api/status")
    }
}

enum HermesBackendProbe {
    private struct StatusPayload: Decodable {
        let version: String
        let hermesHome: String?
        let authRequired: Bool?

        enum CodingKeys: String, CodingKey {
            case version
            case hermesHome = "hermes_home"
            case authRequired = "auth_required"
        }
    }

    static func check(
        serverURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 0.4
    ) async -> HermesBackendProbeResult {
        guard let statusURL = HermesBackendURLBuilder.statusURL(for: serverURL) else {
            return HermesBackendProbeResult(
                reachable: false,
                statusCode: nil,
                version: nil,
                hermesHome: nil,
                authRequired: nil,
                description: "无法构造 Hermes backend 状态地址"
            )
        }
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return HermesBackendProbeResult(
                    reachable: false,
                    statusCode: nil,
                    version: nil,
                    hermesHome: nil,
                    authRequired: nil,
                    description: "Hermes backend 返回了无效响应"
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                return HermesBackendProbeResult(
                    reachable: false,
                    statusCode: http.statusCode,
                    version: nil,
                    hermesHome: nil,
                    authRequired: nil,
                    description: "Hermes backend 状态异常（HTTP \(http.statusCode)）"
                )
            }
            let payload = try JSONDecoder().decode(StatusPayload.self, from: data)
            guard !payload.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: [], debugDescription: "Hermes version 为空")
                )
            }
            return HermesBackendProbeResult(
                reachable: true,
                statusCode: http.statusCode,
                version: payload.version,
                hermesHome: payload.hermesHome,
                authRequired: payload.authRequired,
                description: "Hermes \(payload.version) 已就绪"
            )
        } catch {
            return HermesBackendProbeResult(
                reachable: false,
                statusCode: nil,
                version: nil,
                hermesHome: nil,
                authRequired: nil,
                description: error.localizedDescription
            )
        }
    }
}

enum HermesTemporarySessionToken {
    static func make(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<max(16, byteCount)).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum HermesServeCapabilityCheckResult: Equatable, Sendable {
    case supported
    case explicitlyUnsupported
    case checkFailed(String)
}

enum HermesServeCapabilityDetector {
    static func check(
        executableURL: URL,
        environment: [String: String] = HermesProcessEnvironment.base(),
        timeout: TimeInterval = 5
    ) async -> HermesServeCapabilityCheckResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = executableURL
            process.arguments = ["serve", "--help"]
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                try? output.fileHandleForWriting.close()
                let deadline = Date().addingTimeInterval(max(0.1, timeout))
                while process.isRunning && Date() < deadline && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    process.terminate()
                    let terminationDeadline = Date().addingTimeInterval(1)
                    while process.isRunning && Date() < terminationDeadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                        let killDeadline = Date().addingTimeInterval(1)
                        while process.isRunning && Date() < killDeadline {
                            try? await Task.sleep(for: .milliseconds(25))
                        }
                    }
                    guard !process.isRunning else {
                        return .checkFailed("Hermes serve 能力探测超时，且子进程未能在强制终止后退出")
                    }
                    _ = output.fileHandleForReading.readDataToEndOfFile()
                    return Task.isCancelled
                        ? .checkFailed("Hermes serve 能力探测已取消")
                        : .checkFailed("Hermes serve 能力探测超时；不会自动回退到 Dashboard")
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                guard !Task.isCancelled else {
                    return .checkFailed("Hermes serve 能力探测已取消")
                }
                guard process.terminationReason == .exit else {
                    return .checkFailed("Hermes serve 能力探测被信号终止")
                }
                if process.terminationStatus == 0 {
                    return .supported
                }
                if isExplicitlyUnsupported(text) {
                    return .explicitlyUnsupported
                }
                let diagnostic = conciseDiagnostic(text)
                let suffix = diagnostic.isEmpty ? "" : "：\(diagnostic)"
                return .checkFailed(
                    "Hermes serve 能力探测失败（退出码 \(process.terminationStatus)）\(suffix)"
                )
            } catch {
                try? output.fileHandleForWriting.close()
                return .checkFailed("无法启动 Hermes serve 能力探测：\(error.localizedDescription)")
            }
        }.value
    }

    private static func isExplicitlyUnsupported(_ output: String) -> Bool {
        let value = output.lowercased()
        return value.contains("no such command 'serve'")
            || value.contains("no such command \"serve\"")
            || value.contains("invalid choice: 'serve'")
            || value.contains("invalid choice: \"serve\"")
            || (value.contains("unknown command") && value.contains("serve"))
            || (value.contains("unrecognized command") && value.contains("serve"))
    }

    private static func conciseDiagnostic(_ output: String) -> String {
        let collapsed = output
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(500))
    }
}

@MainActor
protocol HermesBackendProcessManaging: AnyObject {
    var ownsRunningProcess: Bool { get }
    var ownershipPublisher: AnyPublisher<Bool, Never> { get }

    func startHeadlessBackend(
        executableURL: URL,
        serverURL: URL,
        sessionToken: String,
        legacyFallback: Bool,
        additionalEnvironment: [String: String]
    ) throws
    func stopOwnedProcess()
    func recentLog(maxBytes: Int) -> String
}

extension HermesBackendProcessController: HermesBackendProcessManaging {}

@MainActor
protocol HermesChatConnecting: AnyObject {
    var serverText: String { get set }
    var tokenText: String { get set }
    var state: GatewayConnectionState { get }
    var isStreaming: Bool { get }

    func connect() async
    func resumeActiveStoredSessionAfterReconnect() async -> Bool
    func disconnect()
}

extension HermesChatStore: HermesChatConnecting {}

enum HermesBackendCoordinatorState: Equatable {
    case idle
    case checkingPort
    case checkingRuntime
    case startingPrimary
    case startingLegacyFallback
    case waitingForReadiness(attempt: Int)
    case connectingGateway
    case ready(version: String)
    case failed(String)
}

enum HermesServeCapability: String, Codable, Equatable {
    case unknown
    case serveSupported = "serve_supported"
    case serveUnavailable = "serve_unavailable"
    case serveCheckFailed = "serve_check_failed"
    case remote
}

@MainActor
final class HermesBackendCoordinator: ObservableObject {
    typealias Probe = @Sendable (URL) async -> HermesBackendProbeResult
    typealias CapabilityCheck = @Sendable (URL) async -> HermesServeCapabilityCheckResult
    typealias Sleep = @Sendable (Duration) async -> Void

    @Published private(set) var state: HermesBackendCoordinatorState = .idle
    @Published private(set) var statusDetail = ""
    @Published private(set) var backendStatus: HermesBackendProbeResult?
    @Published private(set) var serveCapability: HermesServeCapability = .unknown
    private(set) var sessionToken: String?
    var ownsRunningProcess: Bool { processController.ownsRunningProcess }

    private let processController: HermesBackendProcessManaging
    private let chat: HermesChatConnecting
    private let probe: Probe
    private let capabilityCheck: CapabilityCheck
    private let tokenGenerator: () -> String
    private let sleep: Sleep
    private var ownershipCancellable: AnyCancellable?
    private var expectsOwnedProcess = false
    private var requiresStoredSessionResumeAfterRestart = false
    private var generation = 0

    init(
        processController: HermesBackendProcessManaging,
        chat: HermesChatConnecting,
        probe: @escaping Probe = { await HermesBackendProbe.check(serverURL: $0) },
        capabilityCheck: @escaping CapabilityCheck = {
            await HermesServeCapabilityDetector.check(executableURL: $0)
        },
        tokenGenerator: @escaping () -> String = { HermesTemporarySessionToken.make() },
        sleep: @escaping Sleep = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.processController = processController
        self.chat = chat
        self.probe = probe
        self.capabilityCheck = capabilityCheck
        self.tokenGenerator = tokenGenerator
        self.sleep = sleep
        ownershipCancellable = processController.ownershipPublisher
            // The publisher's initial value describes construction state, not
            // a process exit. If delivery is deferred until after start(), an
            // initial ``false`` can otherwise be mistaken for a crash of the
            // newly launched backend.
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] ownsProcess in
                guard let self, self.expectsOwnedProcess, !ownsProcess else { return }
                if case .ready = self.state {
                    self.requiresStoredSessionResumeAfterRestart = true
                }
                self.chat.disconnect()
                self.state = .failed("Hermes backend 进程意外退出")
                let log = self.processController.recentLog(maxBytes: 12_000)
                self.statusDetail = log.isEmpty ? "请检查 Hermes 安装、端口和 backend 日志。" : log
                self.sessionToken = nil
                self.expectsOwnedProcess = false
            }
    }

    func start(
        executableURL: URL,
        serverURL: URL,
        expectedHermesHome: String? = nil,
        additionalEnvironment: [String: String] = [:],
        maximumAttempts: Int = 60
    ) async {
        resetOwnedRuntimeForRestart()
        generation += 1
        let currentGeneration = generation

        state = .checkingPort
        statusDetail = "正在确认本机端口未被其他 Hermes backend 占用"
        let existing = await probe(serverURL)
        guard currentGeneration == generation else { return }
        if existing.reachable {
            state = .failed("Hermes backend 端口已被占用")
            statusDetail = "\(serverURL.absoluteString) 已有 Hermes \(existing.version ?? "服务") 响应；为避免连接错误实例，本次不会接管或停止它。"
            backendStatus = existing
            return
        }

        state = .checkingRuntime
        statusDetail = "正在检查当前 Hermes 是否支持 headless serve"
        let capability = await capabilityCheck(executableURL)
        guard currentGeneration == generation else { return }
        let useLegacyFallback: Bool
        switch capability {
        case .supported:
            serveCapability = .serveSupported
            useLegacyFallback = false
        case .explicitlyUnsupported:
            serveCapability = .serveUnavailable
            useLegacyFallback = true
        case .checkFailed(let reason):
            serveCapability = .serveCheckFailed
            state = .failed("无法确认 Hermes backend 启动能力")
            statusDetail = reason
            return
        }

        let token = tokenGenerator()
        guard !token.isEmpty else {
            state = .failed("无法生成 Hermes 临时连接 Token")
            statusDetail = "临时 Token 生成器返回空值。"
            return
        }
        sessionToken = token
        state = useLegacyFallback ? .startingLegacyFallback : .startingPrimary
        statusDetail = useLegacyFallback
            ? "当前 Hermes 明确不支持 serve，正在使用 dashboard --no-open 兼容后端"
            : "正在启动 hermes serve"
        expectsOwnedProcess = true
        do {
            try processController.startHeadlessBackend(
                executableURL: executableURL,
                serverURL: serverURL,
                sessionToken: token,
                legacyFallback: useLegacyFallback,
                additionalEnvironment: additionalEnvironment
            )
        } catch {
            expectsOwnedProcess = false
            sessionToken = nil
            state = .failed("启动 Hermes backend 失败")
            statusDetail = error.localizedDescription
            return
        }

        for attempt in 1...max(1, maximumAttempts) {
            guard currentGeneration == generation else { return }
            guard processController.ownsRunningProcess else {
                failOwnedRuntime("Hermes backend 在就绪前退出")
                return
            }
            state = .waitingForReadiness(attempt: attempt)
            let result = await probe(serverURL)
            guard currentGeneration == generation else { return }
            if result.reachable {
                if let expectedHermesHome,
                   result.hermesHome != expectedHermesHome
                {
                    failOwnedRuntime(
                        "Hermes backend 使用了错误的数据目录：预期 \(expectedHermesHome)，实际 \(result.hermesHome ?? "未返回")"
                    )
                    return
                }
                backendStatus = result
                state = .connectingGateway
                statusDetail = "\(result.description)，正在连接 Chat Gateway"
                chat.serverText = serverURL.absoluteString
                chat.tokenText = token
                await chat.connect()
                guard currentGeneration == generation else { return }
                guard chat.state == .ready else {
                    failOwnedRuntime("Hermes backend 已就绪，但 Chat Gateway 连接失败")
                    return
                }
                if requiresStoredSessionResumeAfterRestart {
                    let resumed = await chat.resumeActiveStoredSessionAfterReconnect()
                    guard currentGeneration == generation else { return }
                    guard resumed else {
                        failOwnedRuntime("Hermes backend 已重启，但当前 Session 恢复失败")
                        return
                    }
                    requiresStoredSessionResumeAfterRestart = false
                }
                state = .ready(version: result.version ?? "unknown")
                statusDetail = "Hermes \(result.version ?? "unknown") backend 与 Chat Gateway 已连接"
                return
            }
            statusDetail = "等待 Hermes backend 就绪（第 \(attempt) 次）：\(result.description)"
            await sleep(.milliseconds(250))
        }

        failOwnedRuntime("Hermes backend 启动超时")
    }

    func stop() {
        generation += 1
        expectsOwnedProcess = false
        chat.disconnect()
        processController.stopOwnedProcess()
        sessionToken = nil
        backendStatus = nil
        serveCapability = .unknown
        state = .idle
        statusDetail = ""
    }

    /// Finish a successful handoff to an external/shared backend without
    /// disconnecting the already-established replacement WebSocket.
    func stopOwnedProcessAfterHandoff() {
        generation += 1
        expectsOwnedProcess = false
        processController.stopOwnedProcess()
        sessionToken = nil
        backendStatus = nil
        serveCapability = .unknown
        state = .idle
        statusDetail = ""
    }

    private func resetOwnedRuntimeForRestart() {
        expectsOwnedProcess = false
        chat.disconnect()
        processController.stopOwnedProcess()
        sessionToken = nil
        backendStatus = nil
        serveCapability = .unknown
    }

    private func failOwnedRuntime(_ message: String) {
        let log = processController.recentLog(maxBytes: 12_000)
        expectsOwnedProcess = false
        chat.disconnect()
        processController.stopOwnedProcess()
        sessionToken = nil
        state = .failed(message)
        statusDetail = log.isEmpty ? message : log
    }
}
