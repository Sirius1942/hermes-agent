import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = DashboardConfiguration.default

    var body: some View {
        Form {
            Section("Dashboard") {
                TextField("Dashboard 地址", text: $draft.dashboardURLString)
                    .textFieldStyle(.roundedBorder)
                Text("本地默认地址为 http://127.0.0.1:9119/；远程地址使用现有 Dashboard 登录页面完成认证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("本地不可达时自动启动 Hermes Dashboard", isOn: $draft.autoStartLocalDashboard)
            }

            Section("Hermes 可执行文件") {
                TextField("自动查找，或输入完整路径", text: $draft.hermesExecutablePath)
                    .textFieldStyle(.roundedBorder)
                if let located = model.processController.executableURL {
                    LabeledContent("已找到", value: located.path)
                        .font(.caption)
                }
            }

            Section("外观") {
                Toggle("使用明快主题", isOn: $draft.brightThemeEnabled)
                Text("该主题只注入当前 App 的 WebView，不修改 ~/.hermes/config.yaml 中的 Dashboard 主题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("恢复默认") {
                        draft = .default
                    }
                    Spacer()
                    Button("保存并重新连接") {
                        model.applyConfiguration(draft)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.normalizedDashboardURL == nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Hermes 设置")
        .onAppear {
            draft = model.configuration
            _ = model.processController.locateHermes(
                preferredPath: draft.hermesExecutablePath
            )
        }
    }
}

