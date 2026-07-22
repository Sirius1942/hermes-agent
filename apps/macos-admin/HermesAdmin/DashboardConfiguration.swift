import Foundation

struct DashboardConfiguration: Equatable, Codable {
    static let defaultDashboardURL = URL(string: "http://127.0.0.1:9119/")!

    var dashboardURLString: String
    var hermesExecutablePath: String
    var autoStartLocalDashboard: Bool
    var brightThemeEnabled: Bool

    static let `default` = DashboardConfiguration(
        dashboardURLString: defaultDashboardURL.absoluteString,
        hermesExecutablePath: "",
        autoStartLocalDashboard: true,
        brightThemeEnabled: true
    )

    var normalizedDashboardURL: URL? {
        DashboardURLBuilder.normalize(dashboardURLString)
    }

    var isLocalDashboard: Bool {
        guard let host = normalizedDashboardURL?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

enum DashboardURLBuilder {
    static func normalize(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://") {
            value = "http://\(value)"
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil
        else {
            return nil
        }
        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url
    }

    static func statusURL(for dashboardURL: URL) -> URL? {
        dashboardURL.appending(path: "api/status")
    }
}

enum NavigationDisposition: Equatable {
    case allowInWebView
    case openExternally
    case reject
}

enum DashboardNavigationPolicy {
    static func disposition(
        for candidate: URL,
        dashboardURL: URL,
        allowsCrossOriginRedirect: Bool = false
    ) -> NavigationDisposition {
        guard let scheme = candidate.scheme?.lowercased() else { return .reject }
        if scheme == "about" { return .allowInWebView }
        guard scheme == "http" || scheme == "https" else { return .reject }

        let candidatePort = candidate.port ?? defaultPort(for: scheme)
        let dashboardScheme = dashboardURL.scheme?.lowercased()
        let dashboardPort = dashboardURL.port ?? defaultPort(for: dashboardScheme)
        let sameOrigin = scheme == dashboardScheme
            && candidate.host?.lowercased() == dashboardURL.host?.lowercased()
            && candidatePort == dashboardPort
        if sameOrigin || allowsCrossOriginRedirect {
            return .allowInWebView
        }
        return .openExternally
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
