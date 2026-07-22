import AppKit
import SwiftUI
import WebKit

struct DashboardWebView: NSViewRepresentable {
    let dashboardURL: URL
    let brightThemeEnabled: Bool
    let reloadToken: UUID
    let onTitleChange: (String?) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "HermesAdmin/0.1"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BrightTheme.javascript(enabled: brightThemeEnabled),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        context.coordinator.webView = webView
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastBrightThemeEnabled = brightThemeEnabled
        webView.load(URLRequest(url: dashboardURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            if webView.url == nil || !DashboardWebView.sameDocumentOrigin(
                webView.url,
                dashboardURL
            ) {
                webView.load(URLRequest(url: dashboardURL))
            } else {
                webView.reload()
            }
        }

        if context.coordinator.lastBrightThemeEnabled != brightThemeEnabled {
            context.coordinator.lastBrightThemeEnabled = brightThemeEnabled
            webView.evaluateJavaScript(BrightTheme.javascript(enabled: brightThemeEnabled))
        }
    }

    private static func sameDocumentOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return DashboardNavigationPolicy.disposition(
            for: lhs,
            dashboardURL: rhs
        ) == .allowInWebView
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: DashboardWebView
        weak var webView: WKWebView?
        var lastReloadToken: UUID?
        var lastBrightThemeEnabled = true
        private var contentRecovery = WebContentRecoveryState()

        init(parent: DashboardWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            switch DashboardNavigationPolicy.disposition(
                for: url,
                dashboardURL: parent.dashboardURL,
                // 用户直接点击的外链交给系统浏览器；服务端 302 和脚本导航
                // 必须留在同一 WKWebsiteDataStore 中，才能完成 OAuth PKCE
                // 往返并让回调写入的 Session Cookie 对 Dashboard 可见。
                allowsCrossOriginRedirect: navigationAction.navigationType != .linkActivated
            ) {
            case .allowInWebView:
                decisionHandler(.allow)
            case .openExternally:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .reject:
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let downloads = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first!
            completionHandler(DashboardDownloadDestination.unique(
                in: downloads,
                suggestedFilename: suggestedFilename
            ))
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            parent.onError("下载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            contentRecovery.didFinishNavigation()
            parent.onTitleChange(webView.title)
            webView.evaluateJavaScript(
                BrightTheme.javascript(enabled: parent.brightThemeEnabled)
            )
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.onError(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            switch contentRecovery.actionAfterTermination() {
            case .reload:
                webView.reload()
            case .reportFailure:
                parent.onError("Web 内容进程连续终止，请手动重新加载。")
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            switch DashboardNavigationPolicy.disposition(
                for: url,
                dashboardURL: parent.dashboardURL
            ) {
            case .allowInWebView:
                webView.load(navigationAction.request)
            case .openExternally:
                NSWorkspace.shared.open(url)
            case .reject:
                break
            }
            return nil
        }

    }
}

enum WebContentRecoveryAction: Equatable {
    case reload
    case reportFailure
}

struct WebContentRecoveryState {
    private var hasReloadedAfterTermination = false

    mutating func didFinishNavigation() {
        hasReloadedAfterTermination = false
    }

    mutating func actionAfterTermination() -> WebContentRecoveryAction {
        guard !hasReloadedAfterTermination else { return .reportFailure }
        hasReloadedAfterTermination = true
        return .reload
    }
}

enum DashboardDownloadDestination {
    static func unique(
        in directory: URL,
        suggestedFilename: String,
        fileManager: FileManager = .default
    ) -> URL {
        let leafName = (suggestedFilename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = leafName.isEmpty || leafName == "." || leafName == ".."
            ? "Hermes Download"
            : leafName
        var destination = directory.appending(path: cleanName, directoryHint: .notDirectory)
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            destination = directory.appending(path: name, directoryHint: .notDirectory)
            index += 1
        }
        return destination
    }
}
