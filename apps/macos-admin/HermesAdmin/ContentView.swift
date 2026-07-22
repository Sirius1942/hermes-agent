import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.99, blue: 1.0),
                    Color(red: 1.0, green: 0.97, blue: 0.91),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            content
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Label("Hermes Admin", systemImage: "rectangle.3.group")
                    .font(.headline)

                ConnectionBadge(state: model.connectionState)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(
                    get: { model.configuration.brightThemeEnabled },
                    set: { model.setBrightTheme($0) }
                )) {
                    Label("明快主题", systemImage: "sun.max.fill")
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("mac.admin.theme.toggle")
                .help("切换 App 专属明快主题，不会修改 Dashboard 的共享主题设置")

                Button {
                    model.reloadWebView()
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("mac.admin.dashboard.reload")
                .help("重新加载 Dashboard")

                Button {
                    model.openDashboardInBrowser()
                } label: {
                    Label("在浏览器中打开", systemImage: "safari")
                }
                .accessibilityIdentifier("mac.admin.dashboard.open-browser")
                .help("在默认浏览器中打开当前 Dashboard")

                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .accessibilityIdentifier("mac.admin.settings")
            }
        }
        .navigationTitle(model.pageTitle)
    }

    @ViewBuilder
    private var content: some View {
        switch model.connectionState {
        case .ready:
            if let url = model.dashboardURL {
                DashboardWebView(
                    dashboardURL: url,
                    brightThemeEnabled: model.configuration.brightThemeEnabled,
                    reloadToken: model.webViewReloadToken,
                    onTitleChange: model.reportPageTitle,
                    onError: model.reportWebError
                )
                .accessibilityIdentifier("mac.admin.dashboard.webview")
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                }
                .padding(10)
                .shadow(color: Color.blue.opacity(0.10), radius: 24, y: 10)
            }

        case .idle, .probing, .startingDashboard:
            StatusPanel(
                icon: "sparkles",
                title: model.connectionState.label,
                detail: model.statusDetail,
                showsProgress: true,
                retry: nil
            )

        case .failed(let message):
            StatusPanel(
                icon: "exclamationmark.triangle.fill",
                title: message,
                detail: model.statusDetail,
                showsProgress: false,
                retry: { Task { await model.connect(force: true) } }
            )
        }
    }
}

private struct ConnectionBadge: View {
    let state: AppModel.ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(state.label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes 连接状态：\(state.label)")
        .accessibilityIdentifier("mac.connection.status")
    }

    private var color: Color {
        switch state {
        case .ready: return Color(red: 0.13, green: 0.66, blue: 0.42)
        case .failed: return .red
        case .idle: return .secondary
        case .probing, .startingDashboard: return .orange
        }
    }
}

private struct StatusPanel: View {
    let icon: String
    let title: String
    let detail: String
    let showsProgress: Bool
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: showsProgress ? .repeating : .nonRepeating)

            Text(title)
                .font(.title2.bold())

            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            if showsProgress {
                ProgressView()
                    .controlSize(.large)
            }

            if let retry {
                Button("重试连接", action: retry)
                    .accessibilityIdentifier("mac.connection.retry")
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            SettingsLink {
                Label("连接设置", systemImage: "gearshape")
            }
            .accessibilityIdentifier("mac.connection.settings")
            .buttonStyle(.bordered)
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.12), radius: 30, y: 12)
        .padding(30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.connection.root")
    }
}
