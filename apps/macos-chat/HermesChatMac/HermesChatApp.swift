import AppKit
import SwiftUI

@MainActor
final class HermesChatLifecycleDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: HermesChatRuntime?

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }
}

enum HermesChatRuntimeEnvironment {
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            && environment["HERMES_CHAT_MAC_UI_TESTING"] != "1"
    }
}

@main
struct HermesChatApp: App {
    @NSApplicationDelegateAdaptor(HermesChatLifecycleDelegate.self)
    private var lifecycleDelegate
    @StateObject private var runtime = HermesChatRuntime()
    @AppStorage(
        HermesChatIdentity.autoStartLocalHermesKey,
        store: HermesChatIdentity.defaults
    ) private var autoStartLocalHermes = true
    @AppStorage(
        HermesChatIdentity.localHermesExecutablePathKey,
        store: HermesChatIdentity.defaults
    ) private var localHermesExecutablePath = ""

    var body: some Scene {
        WindowGroup {
            HermesChatWorkbench()
                .environmentObject(runtime)
                .environmentObject(runtime.chat)
                .frame(minWidth: 820, minHeight: 600)
                .task {
                    lifecycleDelegate.runtime = runtime
                    guard !HermesChatRuntimeEnvironment.isRunningUnitTests,
                          autoStartLocalHermes,
                          runtime.state == .idle
                    else { return }
                    await runtime.startLocal(
                        preferredExecutablePath: localHermesExecutablePath
                    )
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        await runtime.refreshSharedBackendIfAvailable()
                    }
                }
        }
        .defaultSize(width: 1420, height: 900)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建 Hermes 会话") {
                    Task { await runtime.chat.createSession() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("停止当前生成") {
                    Task { await runtime.chat.stop() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!runtime.chat.isStreaming)
            }
        }
    }
}
