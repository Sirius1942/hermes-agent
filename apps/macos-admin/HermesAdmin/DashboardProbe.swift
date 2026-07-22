import Foundation

struct DashboardProbeResult: Equatable {
    let reachable: Bool
    let statusCode: Int?
    let description: String
}

enum DashboardProbe {
    static func check(
        dashboardURL: URL,
        session: URLSession = .shared,
        timeout: TimeInterval = 2.5
    ) async -> DashboardProbeResult {
        guard let url = DashboardURLBuilder.statusURL(for: dashboardURL) else {
            return DashboardProbeResult(
                reachable: false,
                statusCode: nil,
                description: "无法构造 Dashboard 状态地址"
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return DashboardProbeResult(
                    reachable: false,
                    statusCode: nil,
                    description: "Dashboard 返回了无效响应"
                )
            }
            let reachable = (200..<500).contains(http.statusCode)
            return DashboardProbeResult(
                reachable: reachable,
                statusCode: http.statusCode,
                description: reachable
                    ? "Dashboard 已响应（HTTP \(http.statusCode)）"
                    : "Dashboard 状态异常（HTTP \(http.statusCode)）"
            )
        } catch {
            return DashboardProbeResult(
                reachable: false,
                statusCode: nil,
                description: error.localizedDescription
            )
        }
    }
}

