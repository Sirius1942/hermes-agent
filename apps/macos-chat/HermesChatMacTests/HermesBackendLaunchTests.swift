import Darwin
import XCTest
@testable import HermesChatMac

final class HermesBackendLaunchTests: XCTestCase {
    func testPrimaryBackendCommandUsesHeadlessServe() {
        XCTAssertEqual(
            HermesBackendLaunchCommand.arguments(
                host: "127.0.0.1",
                port: 19127,
                legacyFallback: false
            ),
            ["serve", "--no-open", "--host", "127.0.0.1", "--port", "19127"]
        )
    }

    func testLegacyFallbackUsesDashboardWithoutOpeningBrowser() {
        XCTAssertEqual(
            HermesBackendLaunchCommand.arguments(
                host: "127.0.0.1",
                port: 19127,
                legacyFallback: true
            ),
            [
                "dashboard",
                "--skip-build",
                "--no-open",
                "--host", "127.0.0.1",
                "--port", "19127",
            ]
        )
    }

    func testSessionTokenIsEnvironmentOnlyAndNeverAppearsInArguments() {
        let spec = HermesBackendLaunchSpec.make(
            host: "127.0.0.1",
            port: 19127,
            sessionToken: "temporary-test-token",
            legacyFallback: false,
            baseEnvironment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(
            spec.environment["HERMES_DASHBOARD_SESSION_TOKEN"],
            "temporary-test-token"
        )
        XCTAssertFalse(spec.arguments.contains("temporary-test-token"))
        XCTAssertEqual(spec.environment["PYTHONUNBUFFERED"], "1")
    }

    @MainActor
    func testHeadlessBackendRejectsRemoteOrMissingToken() async {
        let controller = HermesBackendProcessController()
        let executable = URL(fileURLWithPath: "/usr/bin/true")

        XCTAssertThrowsError(
            try controller.startHeadlessBackend(
                executableURL: executable,
                serverURL: URL(string: "https://agent.example.com:19127")!,
                sessionToken: "token"
            )
        )
        XCTAssertThrowsError(
            try controller.startHeadlessBackend(
                executableURL: executable,
                serverURL: URL(string: "http://127.0.0.1:19127")!,
                sessionToken: ""
            )
        )
    }

    @MainActor
    func testEachOwnedBackendLaunchTruncatesHistoricalLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hermes-backend-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appending(path: "backend.log")
        try "HERMES_BACKEND_READY port=56866\n".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )
        let controller = HermesBackendProcessController(logsDirectory: directory)

        try controller.startHeadlessBackend(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            sessionToken: "memory-only-token"
        )
        let deadline = Date().addingTimeInterval(1)
        while controller.recentLog().isEmpty && Date() < deadline {
            await Task.yield()
        }

        let log = controller.recentLog()
        XCTAssertFalse(log.contains("56866"))
        XCTAssertTrue(log.contains("serve"))
        controller.stopOwnedProcess()
    }

    @MainActor
    func testStopWaitsForOwnedProcessExitAndForceReapsWhenNeeded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hermes-backend-reap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "hermes")
        try "#!/usr/bin/python3\nimport signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint('ready', flush=True)\nwhile True: time.sleep(1)\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let controller = HermesBackendProcessController(
            logsDirectory: directory,
            terminationGracePeriod: 0.05
        )
        try controller.startHeadlessBackend(
            executableURL: executable,
            serverURL: URL(string: "http://127.0.0.1:19127")!,
            sessionToken: "memory-only-token"
        )
        let readyDeadline = Date().addingTimeInterval(1)
        while !controller.recentLog().contains("ready") && Date() < readyDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(controller.ownedProcessIdentifier)

        controller.stopOwnedProcess()

        XCTAssertFalse(controller.ownsRunningProcess)
        XCTAssertNil(controller.ownedProcessIdentifier)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
