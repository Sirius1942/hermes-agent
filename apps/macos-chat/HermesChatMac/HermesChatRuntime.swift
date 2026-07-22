import Combine
import Darwin
import Foundation

enum HermesLoopbackEndpointError: LocalizedError, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case addressReadFailed(Int32)
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code):
            return "无法创建本地 Hermes 端口探测套接字（errno \(code)）"
        case .bindFailed(let code):
            return "无法为本地 Hermes 分配空闲端口（errno \(code)）"
        case .addressReadFailed(let code):
            return "无法读取本地 Hermes 已分配端口（errno \(code)）"
        case .invalidPort:
            return "系统返回了无效的本地 Hermes 端口"
        }
    }
}

enum HermesLoopbackEndpointSelector {
    static func availableURL() throws -> URL {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw HermesLoopbackEndpointError.socketCreationFailed(errno)
        }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw HermesLoopbackEndpointError.bindFailed(errno)
        }

        var assignedAddress = sockaddr_in()
        var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &assignedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &assignedLength)
            }
        }
        guard addressResult == 0 else {
            throw HermesLoopbackEndpointError.addressReadFailed(errno)
        }

        let port = Int(in_port_t(bigEndian: assignedAddress.sin_port))
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw HermesLoopbackEndpointError.invalidPort
        }
        return url
    }
}

enum HermesChatRuntimeState: Equatable {
    case idle
    case startingLocal
    case connectingShared
    case connectingRemote
    case readyLocal(URL)
    case readyShared(URL)
    case readyRemote(URL)
    case failed(String)
}

struct HermesSharedBackendDescriptor: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let owner: String
    let pid: Int32
    let processStartTime: Int64?
    let serverURL: String
    let sessionToken: String
    let hermesHome: String
    let instanceID: String
    let startedAt: Double

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case owner
        case pid
        case processStartTime = "process_start_time"
        case serverURL = "server_url"
        case sessionToken = "session_token"
        case hermesHome = "hermes_home"
        case instanceID = "instance_id"
        case startedAt = "started_at"
    }
}

enum HermesSharedBackendDiscovery {
    static func expectedHermesHome(
        explicit: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) -> String {
        let environment = ProcessInfo.processInfo.environment
        let candidate = [
            explicit,
            additionalEnvironment["HERMES_HOME"],
            environment["HERMES_HOME"],
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".hermes", directoryHint: .isDirectory).path
        return canonicalPath(candidate)
    }

    static func findActive(
        hermesHome: String,
        probe: @escaping @Sendable (URL) async -> HermesBackendProbeResult = {
            await HermesBackendProbe.check(serverURL: $0)
        }
    ) async -> HermesSharedBackendDescriptor? {
        let canonicalHome = canonicalPath(hermesHome)
        let descriptorURL = URL(fileURLWithPath: canonicalHome, isDirectory: true)
            .appending(path: "runtime", directoryHint: .isDirectory)
            .appending(path: "shared-backend.json")

        let descriptor: HermesSharedBackendDescriptor
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: descriptorURL.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber,
               permissions.intValue & 0o077 != 0
            {
                return nil
            }
            let data = try Data(contentsOf: descriptorURL, options: [.mappedIfSafe])
            guard data.count <= 64 * 1_024 else { return nil }
            descriptor = try JSONDecoder().decode(HermesSharedBackendDescriptor.self, from: data)
        } catch {
            return nil
        }

        guard descriptor.schemaVersion == 1,
              descriptor.owner == "gateway",
              descriptor.pid > 0,
              !descriptor.instanceID.isEmpty,
              !descriptor.sessionToken.isEmpty,
              canonicalPath(descriptor.hermesHome) == canonicalHome,
              let serverURL = validatedLoopbackURL(descriptor.serverURL),
              processIsAlive(descriptor.pid),
              processStartTimeMatches(descriptor)
        else {
            removeIfStillOwned(descriptor, at: descriptorURL)
            return nil
        }

        let status = await probe(serverURL)
        guard status.reachable,
              status.authRequired == false,
              status.hermesHome.map(canonicalPath) == canonicalHome
        else {
            // Keep a structurally valid descriptor on transient HTTP/WS
            // failures. The gateway may be busy starting adapters or serving
            // another turn; the next 5-second discovery pass can reconnect.
            return nil
        }
        return descriptor
    }

    private static func canonicalPath(_ rawPath: String) -> String {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func validatedLoopbackURL(_ rawValue: String) -> URL? {
        guard let components = URLComponents(string: rawValue),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port,
              port > 0,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url
        else { return nil }
        return url
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func processStartTimeMatches(
        _ descriptor: HermesSharedBackendDescriptor
    ) -> Bool {
        guard let expected = descriptor.processStartTime else { return true }
        guard let actual = processStartTime(pid: descriptor.pid) else { return false }
        return actual == expected
    }

    static func processStartTime(pid: Int32) -> Int64? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize
        )
        guard result == expectedSize else { return nil }
        // gateway.status quantizes psutil's epoch float with round(... * 100).
        // Mirror that nearest-centisecond rule so the cross-language PID-reuse
        // guard compares byte-for-byte on macOS.
        return Int64(info.pbi_start_tvsec) * 100
            + (Int64(info.pbi_start_tvusec) + 5_000) / 10_000
    }

    private static func removeIfStillOwned(
        _ descriptor: HermesSharedBackendDescriptor,
        at url: URL
    ) {
        guard let data = try? Data(contentsOf: url),
              let current = try? JSONDecoder().decode(
                  HermesSharedBackendDescriptor.self,
                  from: data
              ),
              current.instanceID == descriptor.instanceID
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

struct HermesChatBackendProcessEvidence: Codable, Equatable {
    let schemaVersion: String
    let backendMode: String
    let backendCapability: String
    let ownedProcess: Bool
    let processID: Int32?
    let host: String?
    let port: Int?
    let arguments: [String]
    let sessionTokenInArguments: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case backendMode = "backend_mode"
        case backendCapability = "backend_capability"
        case ownedProcess = "owned_process"
        case processID = "process_id"
        case host
        case port
        case arguments
        case sessionTokenInArguments = "session_token_in_arguments"
    }
}

/// macOS 原生工作台的进程与 Gateway 组合层。
///
/// 它只负责 Hermes runtime 生命周期，不拥有页面布局或视觉样式。正式三栏工作台可以直接观察
/// `chat`、`backend` 和 `state`，无需再经过 Dashboard 或 WKWebView。
@MainActor
final class HermesChatRuntime: ObservableObject {
    typealias ExecutableLocator = (String) -> URL?
    typealias EndpointSelector = () throws -> URL
    typealias SharedBackendDiscoverer = @Sendable (String) async -> HermesSharedBackendDescriptor?

    private struct LocalLaunchRequest {
        let preferredExecutablePath: String
        let expectedHermesHome: String?
        let additionalEnvironment: [String: String]

        var discoveryHermesHome: String {
            HermesSharedBackendDiscovery.expectedHermesHome(
                explicit: expectedHermesHome,
                additionalEnvironment: additionalEnvironment
            )
        }
    }

    @Published private(set) var state: HermesChatRuntimeState = .idle
    @Published private(set) var statusDetail = ""

    let chat: HermesChatStore
    let processController: HermesBackendProcessController
    let backend: HermesBackendCoordinator

    private let chatConnection: HermesChatConnecting
    private let executableLocator: ExecutableLocator
    private let endpointSelector: EndpointSelector
    private let sharedBackendDiscoverer: SharedBackendDiscoverer
    private var backendStateCancellable: AnyCancellable?
    private var lastLocalLaunchRequest: LocalLaunchRequest?
    private var sharedBackendRefreshInProgress = false
    private var sharedBackendRetryAfter: Date?
    private var activeSharedBackendInstanceID: String?
    private var generation = 0

    init(
        chat: HermesChatStore? = nil,
        chatConnection: HermesChatConnecting? = nil,
        processController: HermesBackendProcessController? = nil,
        backendCoordinator: HermesBackendCoordinator? = nil,
        executableLocator: ExecutableLocator? = nil,
        endpointSelector: @escaping EndpointSelector = HermesLoopbackEndpointSelector.availableURL,
        sharedBackendDiscoverer: @escaping SharedBackendDiscoverer = {
            await HermesSharedBackendDiscovery.findActive(hermesHome: $0)
        }
    ) {
        let resolvedChat: HermesChatStore
        if let chat {
            resolvedChat = chat
        } else {
            let keychain = HermesChatKeychainStore()
            resolvedChat = HermesChatStore(
                source: "macos-chat",
                gateway: HermesGateway(clientID: "macos-chat"),
                loadStoredToken: { keychain.load() },
                saveStoredToken: { try keychain.save(token: $0) }
            )
        }
        let resolvedProcessController = processController ?? HermesBackendProcessController()
        self.chat = resolvedChat
        self.chatConnection = chatConnection ?? resolvedChat
        self.processController = resolvedProcessController
        let resolvedBackend = backendCoordinator ?? HermesBackendCoordinator(
            processController: resolvedProcessController,
            chat: resolvedChat
        )
        self.backend = resolvedBackend
        self.executableLocator = executableLocator ?? { preferredPath in
            resolvedProcessController.locateHermes(preferredPath: preferredPath)
        }
        self.endpointSelector = endpointSelector
        self.sharedBackendDiscoverer = sharedBackendDiscoverer
        backendStateCancellable = resolvedBackend.$state
            .combineLatest(resolvedBackend.$statusDetail)
            .receive(on: RunLoop.main)
            .sink { [weak self] backendState, detail in
                guard let self, case .failed(let message) = backendState else { return }
                self.state = .failed(message)
                self.statusDetail = detail.isEmpty ? message : "\(message)\n\(detail)"
            }
    }

    func startLocal(
        preferredExecutablePath: String = "",
        expectedHermesHome: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) async {
        stop()
        let currentGeneration = generation
        sharedBackendRetryAfter = nil
        let request = LocalLaunchRequest(
            preferredExecutablePath: preferredExecutablePath,
            expectedHermesHome: expectedHermesHome,
            additionalEnvironment: additionalEnvironment
        )
        lastLocalLaunchRequest = request
        state = .startingLocal
        statusDetail = "正在查找 gateway 共享的 Hermes backend"

        let descriptor = await sharedBackendDiscoverer(request.discoveryHermesHome)
        guard currentGeneration == generation, !Task.isCancelled else { return }
        if let descriptor,
           await connectSharedBackend(
               descriptor,
               resumeStoredSession: false,
               generation: currentGeneration
           )
        {
            return
        }

        guard currentGeneration == generation, !Task.isCancelled else { return }
        await startOwnedLocal(
            request,
            resumeStoredSession: false,
            generation: currentGeneration
        )
    }

    /// Re-check discovery after startup so a gateway launched later can take
    /// over from the app-owned ``hermes serve`` process.  The current Session
    /// is resumed after reconnect; an active generation is never interrupted.
    func refreshSharedBackendIfAvailable() async {
        let wasOwnedLocal: Bool
        switch state {
        case .readyLocal:
            wasOwnedLocal = true
        case .readyShared:
            wasOwnedLocal = false
        default:
            return
        }
        let currentGeneration = generation
        guard !chatConnection.isStreaming,
              !sharedBackendRefreshInProgress,
              sharedBackendRetryAfter.map({ $0 <= Date() }) ?? true,
              let request = lastLocalLaunchRequest,
              !Task.isCancelled
        else { return }

        sharedBackendRefreshInProgress = true
        defer { sharedBackendRefreshInProgress = false }
        let descriptor = await sharedBackendDiscoverer(request.discoveryHermesHome)
        guard currentGeneration == generation,
              !chatConnection.isStreaming,
              !Task.isCancelled
        else { return }

        if wasOwnedLocal {
            guard case .readyLocal = state, let descriptor else { return }
        } else {
            guard case .readyShared = state else { return }
            if descriptor == nil {
                guard chatConnection.state != .ready else { return }
                activeSharedBackendInstanceID = nil
                statusDetail = "Gateway 已停止，正在恢复 app 自有 backend"
                await startOwnedLocal(
                    request,
                    resumeStoredSession: true,
                    generation: currentGeneration
                )
                return
            }
            if descriptor?.instanceID == activeSharedBackendInstanceID,
               chatConnection.state == .ready
            {
                return
            }
        }

        if let descriptor,
           await connectSharedBackend(
               descriptor,
               resumeStoredSession: true,
               generation: currentGeneration
           )
        {
            return
        }

        if case .readyLocal = state { return }

        statusDetail = "共享 gateway 连接失败，正在恢复 app 自有 backend"
        await startOwnedLocal(
            request,
            resumeStoredSession: true,
            generation: currentGeneration
        )
    }

    private func startOwnedLocal(
        _ request: LocalLaunchRequest,
        resumeStoredSession: Bool,
        generation currentGeneration: Int
    ) async {
        guard currentGeneration == generation, !Task.isCancelled else { return }
        activeSharedBackendInstanceID = nil
        state = .startingLocal
        statusDetail = "正在准备 app 自有 Hermes backend"

        guard let executableURL = executableLocator(request.preferredExecutablePath) else {
            fail("未找到 Hermes 可执行文件", detail: "请安装 Hermes，或在高级设置中选择 hermes 可执行文件。")
            return
        }

        let serverURL: URL
        do {
            serverURL = try endpointSelector()
        } catch {
            fail("无法分配本地 Hermes 端口", detail: error.localizedDescription)
            return
        }

        statusDetail = "正在 \(serverURL.host ?? "127.0.0.1"):\(serverURL.port ?? 0) 启动 hermes serve"
        await backend.start(
            executableURL: executableURL,
            serverURL: serverURL,
            expectedHermesHome: request.expectedHermesHome,
            additionalEnvironment: request.additionalEnvironment
        )
        guard currentGeneration == generation, !Task.isCancelled else { return }

        switch backend.state {
        case .ready:
            if resumeStoredSession,
               !(await chatConnection.resumeActiveStoredSessionAfterReconnect())
            {
                guard currentGeneration == generation else { return }
                fail("app 自有 Hermes backend 已恢复，但当前 Session 恢复失败", detail: backend.statusDetail)
                return
            }
            guard currentGeneration == generation, !Task.isCancelled else { return }
            state = .readyLocal(serverURL)
            statusDetail = backend.statusDetail
        case .failed(let message):
            fail(message, detail: backend.statusDetail)
        default:
            fail("本地 Hermes backend 未进入就绪状态", detail: backend.statusDetail)
        }
    }

    private func connectSharedBackend(
        _ descriptor: HermesSharedBackendDescriptor,
        resumeStoredSession: Bool,
        generation currentGeneration: Int
    ) async -> Bool {
        guard currentGeneration == generation, !Task.isCancelled else { return false }
        guard let serverURL = URL(string: descriptor.serverURL) else { return false }

        let ownedServerURL: URL?
        if case .readyLocal(let currentURL) = state,
           backend.ownsRunningProcess
        {
            ownedServerURL = currentURL
        } else {
            ownedServerURL = nil
        }
        let ownedSessionToken = ownedServerURL == nil ? nil : backend.sessionToken

        if ownedServerURL == nil {
            backend.stop()
        } else {
            // Keep the child alive until the replacement connection and its
            // Session resume have both succeeded. This makes handoff atomic
            // from the user's perspective and avoids restart churn on a
            // transient shared-WebSocket failure.
            chatConnection.disconnect()
        }
        state = .connectingShared
        statusDetail = "正在连接 gateway 进程内的共享 Hermes backend"
        chatConnection.serverText = serverURL.absoluteString
        chatConnection.tokenText = descriptor.sessionToken
        await chatConnection.connect()
        guard currentGeneration == generation, !Task.isCancelled else { return false }

        guard chatConnection.state == .ready else {
            chatConnection.disconnect()
            await restoreOwnedConnectionIfPossible(
                serverURL: ownedServerURL,
                sessionToken: ownedSessionToken,
                resumeStoredSession: resumeStoredSession,
                generation: currentGeneration
            )
            sharedBackendRetryAfter = Date().addingTimeInterval(30)
            return false
        }
        if resumeStoredSession,
           !(await chatConnection.resumeActiveStoredSessionAfterReconnect())
        {
            guard currentGeneration == generation else { return false }
            chatConnection.disconnect()
            await restoreOwnedConnectionIfPossible(
                serverURL: ownedServerURL,
                sessionToken: ownedSessionToken,
                resumeStoredSession: true,
                generation: currentGeneration
            )
            sharedBackendRetryAfter = Date().addingTimeInterval(30)
            return false
        }
        guard currentGeneration == generation, !Task.isCancelled else { return false }

        if ownedServerURL != nil {
            // This only stops the child process the app owns. The discovered
            // gateway is external to the coordinator and is never terminated
            // by Stop or applicationWillTerminate.
            backend.stopOwnedProcessAfterHandoff()
        }
        sharedBackendRetryAfter = nil
        activeSharedBackendInstanceID = descriptor.instanceID
        state = .readyShared(serverURL)
        statusDetail = "消息 Gateway 与 macOS Chat 正在使用同一个 Hermes backend 进程"
        return true
    }

    private func restoreOwnedConnectionIfPossible(
        serverURL: URL?,
        sessionToken: String?,
        resumeStoredSession: Bool,
        generation currentGeneration: Int
    ) async {
        guard currentGeneration == generation,
              !Task.isCancelled,
              let serverURL,
              let sessionToken,
              backend.ownsRunningProcess
        else { return }

        chatConnection.serverText = serverURL.absoluteString
        chatConnection.tokenText = sessionToken
        await chatConnection.connect()
        guard currentGeneration == generation,
              !Task.isCancelled,
              chatConnection.state == .ready
        else { return }
        if resumeStoredSession,
           !(await chatConnection.resumeActiveStoredSessionAfterReconnect())
        {
            guard currentGeneration == generation else { return }
            chatConnection.disconnect()
            return
        }
        guard currentGeneration == generation, !Task.isCancelled else { return }
        state = .readyLocal(serverURL)
        statusDetail = "共享 gateway 暂不可用，已保持 app 自有 backend 连接"
    }

    func connectRemote(serverURL: URL, token: String?) async {
        stop()
        let currentGeneration = generation
        state = .connectingRemote
        statusDetail = "正在连接远程 Hermes"
        chatConnection.serverText = serverURL.absoluteString
        chatConnection.tokenText = token ?? ""
        await chatConnection.connect()
        guard currentGeneration == generation, !Task.isCancelled else { return }

        switch chatConnection.state {
        case .ready:
            state = .readyRemote(serverURL)
            statusDetail = "远程 Hermes 与 Chat Gateway 已连接"
        case .failed(let message):
            fail("远程 Hermes 连接失败", detail: message)
        case .connecting:
            fail("远程 Hermes 连接未完成", detail: "Gateway 仍处于连接状态")
        case .disconnected:
            fail("远程 Hermes 已断开", detail: "Gateway 未能保持连接")
        }
    }

    func stop() {
        generation += 1
        backend.stop()
        activeSharedBackendInstanceID = nil
        state = .idle
        statusDetail = ""
    }

    func backendProcessEvidence() -> HermesChatBackendProcessEvidence {
        let mode: String
        let capability: String
        switch state {
        case .readyShared:
            mode = "shared_gateway"
            capability = "shared_gateway"
        case .readyRemote:
            mode = "remote"
            capability = HermesServeCapability.remote.rawValue
        default:
            mode = processController.ownedMode?.evidenceValue ?? "unknown"
            capability = backend.serveCapability.rawValue
        }
        let arguments = processController.ownedArguments
        let tokenInArguments = backend.sessionToken.map { token in
            !token.isEmpty && arguments.contains(where: { $0.contains(token) })
        } ?? false
        return HermesChatBackendProcessEvidence(
            schemaVersion: "1",
            backendMode: mode,
            backendCapability: capability,
            ownedProcess: processController.ownsRunningProcess,
            processID: processController.ownedProcessIdentifier,
            host: processController.ownedHost,
            port: processController.ownedPort,
            arguments: arguments,
            sessionTokenInArguments: tokenInArguments
        )
    }

    private func fail(_ message: String, detail: String) {
        state = .failed(message)
        statusDetail = detail.isEmpty ? message : detail
    }
}
