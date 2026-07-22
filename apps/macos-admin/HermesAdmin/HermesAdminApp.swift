import AppKit
import SwiftUI

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var processController: DashboardProcessController?

    func applicationWillTerminate(_ notification: Notification) {
        processController?.stopOwnedDashboard()
    }
}

enum HermesAdminRuntimeEnvironment {
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            && environment["HERMES_MAC_UI_TESTING"] != "1"
    }
}

@main
struct HermesAdminApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    lifecycleDelegate.processController = model.processController
                    guard !HermesAdminRuntimeEnvironment.isRunningUnitTests else { return }
                    await model.connect()
                }
        }
        .defaultSize(width: 1380, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重新连接 Hermes") {
                    Task { await model.connect(force: true) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("重新加载页面") {
                    model.reloadWebView()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560)
        }
    }
}
