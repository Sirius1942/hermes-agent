import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case probing
        case startingDashboard
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "尚未连接"
            case .probing: return "正在连接"
            case .startingDashboard: return "正在启动 Hermes"
            case .ready: return "已连接"
            case .failed: return "连接失败"
            }
        }
    }

    @Published var configuration: DashboardConfiguration
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var webViewReloadToken = UUID()
    @Published private(set) var statusDetail = ""
    @Published private(set) var pageTitle = "Hermes Admin"
    @Published var showsSettings = false

    let processController = DashboardProcessController()

    private let defaults = HermesAdminIdentity.defaults
    private let defaultsKey = HermesAdminIdentity.configurationKey
    private var connectionGeneration = 0

    init() {
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(DashboardConfiguration.self, from: data) {
            configuration = stored
        } else {
            configuration = .default
        }
    }

    var dashboardURL: URL? { configuration.normalizedDashboardURL }

    func connect(force: Bool = false) async {
        if !force {
            switch connectionState {
            case .probing, .startingDashboard, .ready:
                return
            case .idle, .failed:
                break
            }
        }
        guard let dashboardURL else {
            connectionState = .failed("Dashboard 地址无效")
            statusDetail = "请在设置中输入 http:// 或 https:// 地址。"
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        connectionState = .probing
        statusDetail = "正在检查 \(dashboardURL.absoluteString)"

        let initial = await DashboardProbe.check(dashboardURL: dashboardURL)
        guard generation == connectionGeneration else { return }
        if initial.reachable {
            markReady(detail: initial.description)
            return
        }

        guard configuration.autoStartLocalDashboard, configuration.isLocalDashboard else {
            connectionState = .failed("无法连接 Dashboard")
            statusDetail = initial.description
            return
        }

        guard let executable = processController.locateHermes(
            preferredPath: configuration.hermesExecutablePath
        ) else {
            connectionState = .failed("未找到 Hermes")
            statusDetail = "请安装 Hermes，或在设置中选择 hermes 可执行文件。"
            return
        }

        do {
            connectionState = .startingDashboard
            statusDetail = "正在使用 \(executable.path) 启动本地 Dashboard"
            try processController.startDashboard(
                executableURL: executable,
                dashboardURL: dashboardURL
            )
        } catch {
            connectionState = .failed("启动 Dashboard 失败")
            statusDetail = error.localizedDescription
            return
        }

        for attempt in 1...60 {
            guard generation == connectionGeneration else { return }
            try? await Task.sleep(for: .milliseconds(500))
            let result = await DashboardProbe.check(
                dashboardURL: dashboardURL,
                timeout: 1.0
            )
            if result.reachable {
                markReady(detail: "Dashboard 已启动（第 \(attempt) 次检查）")
                return
            }
        }

        connectionState = .failed("Dashboard 启动超时")
        let log = processController.recentLog()
        processController.stopOwnedDashboard()
        statusDetail = log.isEmpty ? "请检查 Hermes 安装和端口。" : log
    }

    func applyConfiguration(_ newValue: DashboardConfiguration) {
        let endpointChanged = configuration.normalizedDashboardURL
            != newValue.normalizedDashboardURL
        let launcherChanged = configuration.hermesExecutablePath
            != newValue.hermesExecutablePath
        if endpointChanged || launcherChanged || !newValue.autoStartLocalDashboard {
            processController.stopOwnedDashboard()
        }
        configuration = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            defaults.set(data, forKey: defaultsKey)
        }
        webViewReloadToken = UUID()
        connectionState = .idle
        Task { await connect(force: true) }
    }

    func setBrightTheme(_ enabled: Bool) {
        configuration.brightThemeEnabled = enabled
        if let data = try? JSONEncoder().encode(configuration) {
            defaults.set(data, forKey: defaultsKey)
        }
        objectWillChange.send()
    }

    func reloadWebView() {
        webViewReloadToken = UUID()
    }

    func openDashboardInBrowser() {
        guard let dashboardURL else { return }
        NSWorkspace.shared.open(dashboardURL)
    }

    func reportPageTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            pageTitle = "Hermes Admin"
            return
        }
        if trimmed.caseInsensitiveCompare("Hermes") == .orderedSame
            || trimmed.caseInsensitiveCompare("Hermes Admin") == .orderedSame {
            pageTitle = "Hermes Admin"
        } else if trimmed.range(
            of: "Hermes Admin — ",
            options: [.anchored, .caseInsensitive]
        ) != nil {
            pageTitle = trimmed
        } else {
            pageTitle = "Hermes Admin — \(trimmed)"
        }
    }

    func reportWebError(_ message: String) {
        statusDetail = message
    }

    private func markReady(detail: String) {
        connectionState = .ready
        statusDetail = detail
        webViewReloadToken = UUID()
    }
}
