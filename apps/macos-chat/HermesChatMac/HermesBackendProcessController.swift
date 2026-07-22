import Combine
import Darwin
import Foundation

struct HermesExecutableLocator {
    static func locate(
        preferredPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        candidates(
            preferredPath: preferredPath,
            environment: environment,
            homeDirectory: homeDirectory
        ).first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    static func candidates(
        preferredPath: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        var values: [String] = []
        let preferred = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { values.append((preferred as NSString).expandingTildeInPath) }
        values.append(contentsOf: (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/hermes" })
        values.append(homeDirectory.appending(path: ".local/bin/hermes").path)
        values.append("/opt/homebrew/bin/hermes")
        values.append("/usr/local/bin/hermes")
        values.append("/usr/bin/hermes")

        var seen = Set<String>()
        return values.compactMap { value in
            let candidate = URL(fileURLWithPath: value).standardizedFileURL
            return seen.insert(candidate.path).inserted ? candidate : nil
        }
    }
}

@MainActor
final class HermesBackendProcessController: ObservableObject {
    @Published private(set) var ownsRunningProcess = false
    @Published private(set) var executableURL: URL?
    @Published private(set) var logURL: URL?
    @Published private(set) var ownedProcessIdentifier: Int32?
    @Published private(set) var ownedMode: HermesOwnedProcessMode?
    @Published private(set) var ownedArguments: [String] = []
    @Published private(set) var ownedHost: String?
    @Published private(set) var ownedPort: Int?

    private var process: Process?
    private var logHandle: FileHandle?
    private let logsDirectory: URL
    private let terminationGracePeriod: TimeInterval

    init(
        logsDirectory: URL? = nil,
        terminationGracePeriod: TimeInterval = 1
    ) {
        self.logsDirectory = logsDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first!
                .appending(path: "HermesChat", directoryHint: .isDirectory)
        self.terminationGracePeriod = max(0.05, terminationGracePeriod)
    }

    var ownershipPublisher: AnyPublisher<Bool, Never> {
        $ownsRunningProcess.eraseToAnyPublisher()
    }

    func locateHermes(preferredPath: String) -> URL? {
        let value = HermesExecutableLocator.locate(preferredPath: preferredPath)
        executableURL = value
        return value
    }

    func startHeadlessBackend(
        executableURL: URL,
        serverURL: URL,
        sessionToken: String,
        legacyFallback: Bool = false,
        additionalEnvironment: [String: String] = [:]
    ) throws {
        guard !sessionToken.isEmpty else { throw HermesBackendProcessError.missingSessionToken }
        guard let host = serverURL.host,
              ["127.0.0.1", "localhost", "::1"].contains(host),
              serverURL.scheme?.lowercased() == "http"
        else {
            throw HermesBackendProcessError.onlyLoopbackHTTP
        }
        let port = serverURL.port ?? 80
        let spec = HermesBackendLaunchSpec.make(
            host: host,
            port: port,
            sessionToken: sessionToken,
            legacyFallback: legacyFallback,
            additionalEnvironment: additionalEnvironment
        )
        try startOwnedProcess(
            executableURL: executableURL,
            arguments: spec.arguments,
            environment: spec.environment,
            mode: legacyFallback ? .legacyHeadlessFallback : .headlessBackend,
            host: host,
            port: port
        )
    }

    private func startOwnedProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        mode: HermesOwnedProcessMode,
        host: String,
        port: Int
    ) throws {
        guard process == nil else { return }
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appending(path: "backend.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        // `recentLog()` must describe this launch only. Reusing an appended cache file made
        // historical READY ports look like output from the current owned backend attempt.
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)

        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = environment
        child.standardOutput = handle
        child.standardError = handle
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.handleTermination(of: terminated) }
        }
        do {
            try child.run()
        } catch {
            child.terminationHandler = nil
            try? handle.close()
            throw error
        }
        process = child
        logHandle = handle
        self.logURL = logURL
        self.executableURL = executableURL
        ownsRunningProcess = true
        ownedProcessIdentifier = child.processIdentifier
        ownedMode = mode
        ownedArguments = arguments
        ownedHost = host
        ownedPort = port
    }

    func stopOwnedProcess() {
        guard let process else { return }
        process.terminationHandler = nil
        terminateAndReap(process)
        self.process = nil
        clearOwnership()
    }

    func recentLog(maxBytes: Int = 12_000) -> String {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return "" }
        return String(data: data.suffix(maxBytes), encoding: .utf8) ?? ""
    }

    private func handleTermination(of terminated: Process) {
        guard process === terminated else { return }
        process = nil
        clearOwnership()
    }

    private func terminateAndReap(_ child: Process) {
        guard child.isRunning else {
            child.waitUntilExit()
            return
        }

        child.terminate()
        var deadline = Date().addingTimeInterval(terminationGracePeriod)
        while child.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if child.isRunning {
            Darwin.kill(child.processIdentifier, SIGKILL)
            deadline = Date().addingTimeInterval(1)
            while child.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // This is an owned child process. Reaping it before clearing ownership prevents an
        // orphan or zombie from surviving after the UI claims the backend has stopped.
        child.waitUntilExit()
    }

    private func clearOwnership() {
        ownsRunningProcess = false
        ownedProcessIdentifier = nil
        ownedMode = nil
        ownedArguments = []
        ownedHost = nil
        ownedPort = nil
        try? logHandle?.close()
        logHandle = nil
    }
}

enum HermesOwnedProcessMode: String, Codable, Equatable {
    case headlessBackend
    case legacyHeadlessFallback

    var evidenceValue: String {
        switch self {
        case .headlessBackend: return "serve"
        case .legacyHeadlessFallback: return "legacy_headless_fallback"
        }
    }
}

enum HermesBackendProcessError: LocalizedError {
    case onlyLoopbackHTTP
    case missingSessionToken

    var errorDescription: String? {
        switch self {
        case .onlyLoopbackHTTP:
            return "Hermes Chat 只能启动使用 HTTP 的本机 loopback backend。"
        case .missingSessionToken:
            return "启动本机 Hermes backend 前必须生成临时连接 Token。"
        }
    }
}

enum HermesProcessEnvironment {
    static func base(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = environment
        result["PATH"] = [
            environment["PATH"] ?? "",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ].filter { !$0.isEmpty }.joined(separator: ":")
        result["PYTHONUNBUFFERED"] = "1"
        return result
    }
}

struct HermesBackendLaunchSpec {
    let arguments: [String]
    let environment: [String: String]

    static func make(
        host: String,
        port: Int,
        sessionToken: String,
        legacyFallback: Bool,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalEnvironment: [String: String] = [:]
    ) -> HermesBackendLaunchSpec {
        var environment = HermesProcessEnvironment.base(environment: baseEnvironment)
        environment.merge(additionalEnvironment) { _, new in new }
        environment["HERMES_DASHBOARD_SESSION_TOKEN"] = sessionToken
        return HermesBackendLaunchSpec(
            arguments: HermesBackendLaunchCommand.arguments(
                host: host,
                port: port,
                legacyFallback: legacyFallback
            ),
            environment: environment
        )
    }
}

enum HermesBackendLaunchCommand {
    static func arguments(host: String, port: Int, legacyFallback: Bool) -> [String] {
        if legacyFallback {
            return [
                "dashboard", "--skip-build", "--no-open",
                "--host", host, "--port", String(port),
            ]
        }
        return ["serve", "--no-open", "--host", host, "--port", String(port)]
    }
}
