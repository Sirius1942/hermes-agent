import Combine
import Foundation

struct HermesExecutableLocator {
    static func locate(
        preferredPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in candidates(
            preferredPath: preferredPath,
            environment: environment,
            homeDirectory: homeDirectory
        ) where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static func candidates(
        preferredPath: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> [URL] {
        var values: [String] = []
        let preferred = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferred.isEmpty { values.append((preferred as NSString).expandingTildeInPath) }

        let pathValues = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/hermes" }
        values.append(contentsOf: pathValues)
        values.append(homeDirectory.appending(path: ".local/bin/hermes").path)
        values.append("/opt/homebrew/bin/hermes")
        values.append("/usr/local/bin/hermes")
        values.append("/usr/bin/hermes")

        var seen = Set<String>()
        return values.compactMap { value in
            let standardized = URL(fileURLWithPath: value).standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }
}

@MainActor
final class DashboardProcessController: ObservableObject {
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

    var ownershipPublisher: AnyPublisher<Bool, Never> {
        $ownsRunningProcess.eraseToAnyPublisher()
    }

    func locateHermes(preferredPath: String) -> URL? {
        let located = HermesExecutableLocator.locate(preferredPath: preferredPath)
        executableURL = located
        return located
    }

    func startDashboard(
        executableURL: URL,
        dashboardURL: URL
    ) throws {
        let port = dashboardURL.port ?? (dashboardURL.scheme == "https" ? 443 : 80)
        let host = try localHTTPHost(for: dashboardURL)
        try startOwnedProcess(
            executableURL: executableURL,
            arguments: DashboardLaunchCommand.arguments(host: host, port: port),
            environment: HermesProcessEnvironment.base(),
            logFilename: "dashboard.log",
            mode: .dashboard,
            host: host,
            port: port
        )
    }

    func startHeadlessBackend(
        executableURL: URL,
        serverURL: URL,
        sessionToken: String,
        legacyFallback: Bool = false,
        additionalEnvironment: [String: String] = [:]
    ) throws {
        guard !sessionToken.isEmpty else {
            throw DashboardProcessError.missingBackendSessionToken
        }
        let port = serverURL.port ?? 80
        let host = try localHTTPHost(for: serverURL)
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
            logFilename: "backend.log",
            mode: legacyFallback ? .legacyHeadlessFallback : .headlessBackend,
            host: host,
            port: port
        )
    }

    private func localHTTPHost(for url: URL) throws -> String {
        guard let host = url.host,
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              url.scheme?.lowercased() == "http"
        else {
            throw DashboardProcessError.onlyLocalHTTPDashboardCanBeStarted
        }
        return host
    }

    private func startOwnedProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        logFilename: String,
        mode: HermesOwnedProcessMode,
        host: String,
        port: Int
    ) throws {
        guard process == nil else { return }

        let logsDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!.appending(path: "HermesAdmin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        let logURL = logsDirectory.appending(path: logFilename)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleTermination(of: terminatedProcess)
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            try? handle.close()
            throw error
        }
        self.process = process
        self.logHandle = handle
        self.logURL = logURL
        self.ownsRunningProcess = true
        self.ownedProcessIdentifier = process.processIdentifier
        self.ownedMode = mode
        self.ownedArguments = arguments
        self.ownedHost = host
        self.ownedPort = port
    }

    func stopOwnedProcess() {
        guard ownsRunningProcess, let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        ownsRunningProcess = false
        ownedProcessIdentifier = nil
        ownedMode = nil
        ownedArguments = []
        ownedHost = nil
        ownedPort = nil
        try? logHandle?.close()
        logHandle = nil
    }

    func stopOwnedDashboard() {
        stopOwnedProcess()
    }

    func recentLog(maxBytes: Int = 12_000) -> String {
        guard let logURL,
              let data = try? Data(contentsOf: logURL)
        else { return "" }
        let suffix = data.suffix(maxBytes)
        return String(data: suffix, encoding: .utf8) ?? ""
    }

    private func handleTermination(of terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        process = nil
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
    case dashboard
    case headlessBackend
    case legacyHeadlessFallback

    var evidenceValue: String {
        switch self {
        case .dashboard: return "dashboard_ui"
        case .headlessBackend: return "serve"
        case .legacyHeadlessFallback: return "legacy_headless_fallback"
        }
    }
}

enum DashboardProcessError: LocalizedError {
    case onlyLocalHTTPDashboardCanBeStarted
    case missingBackendSessionToken

    var errorDescription: String? {
        switch self {
        case .onlyLocalHTTPDashboardCanBeStarted:
            return "只能自动启动使用 HTTP 的本机 Dashboard；HTTPS 或远程地址必须由服务器端自行运行。"
        case .missingBackendSessionToken:
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
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
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
                "dashboard",
                "--skip-build",
                "--no-open",
                "--host", host,
                "--port", String(port),
            ]
        }
        return [
            "serve",
            "--no-open",
            "--host", host,
            "--port", String(port),
        ]
    }
}

enum DashboardLaunchCommand {
    static func arguments(host: String, port: Int) -> [String] {
        [
            "dashboard",
            "--skip-build",
            "--no-open",
            "--host", host,
            "--port", String(port),
        ]
    }
}
