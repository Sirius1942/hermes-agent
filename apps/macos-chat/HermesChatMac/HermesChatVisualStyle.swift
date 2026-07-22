import SwiftUI

enum HermesChatPalette {
    static let blue = Color(red: 0.13, green: 0.43, blue: 0.95)
    static let cyan = Color(red: 0.10, green: 0.73, blue: 0.82)
    static let coral = Color(red: 1.00, green: 0.45, blue: 0.34)
    static let green = Color(red: 0.10, green: 0.66, blue: 0.42)
    static let ink = Color(red: 0.08, green: 0.13, blue: 0.21)
    static let muted = Color(red: 0.36, green: 0.43, blue: 0.53)
    static let canvas = Color(red: 0.95, green: 0.97, blue: 1.00)
    static let panel = Color.white.opacity(0.94)
}

struct HermesPageMarker: View {
    let identifier: String
    let label: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

struct HermesStatusPill: View {
    let title: String
    let color: Color
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

extension HermesChatRuntimeState {
    var label: String {
        switch self {
        case .idle: return "未连接"
        case .startingLocal: return "正在启动本地 Hermes"
        case .connectingShared: return "正在连接共享 Hermes"
        case .connectingRemote: return "正在连接远程 Hermes"
        case .readyLocal: return "本地 Hermes 在线"
        case .readyShared: return "Gateway 共享 Hermes 在线"
        case .readyRemote: return "远程 Hermes 在线"
        case .failed: return "连接需要处理"
        }
    }

    var color: Color {
        switch self {
        case .readyLocal, .readyShared, .readyRemote: return HermesChatPalette.green
        case .startingLocal, .connectingShared, .connectingRemote: return .orange
        case .failed: return HermesChatPalette.coral
        case .idle: return HermesChatPalette.muted
        }
    }

    var symbol: String {
        switch self {
        case .readyLocal, .readyShared, .readyRemote: return "checkmark.circle.fill"
        case .startingLocal, .connectingShared, .connectingRemote: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "circle.dashed"
        }
    }

    var isLocalConnectionReady: Bool {
        switch self {
        case .readyLocal, .readyShared: return true
        default: return false
        }
    }

    var isConnectionReady: Bool {
        switch self {
        case .readyLocal, .readyShared, .readyRemote: return true
        default: return false
        }
    }
}

extension ChatWorkspacePhase {
    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .ready: return "就绪"
        case .loadingSession: return "正在加载会话"
        case .streaming: return "Hermes 正在回复"
        case .stopping: return "正在停止"
        case .interrupted: return "已停止"
        case .awaitingInput: return "等待你的输入"
        case .recovering: return "正在恢复连接"
        case .configurationRequired: return "需要配置模型服务"
        case .providerConfigurationSavedAwaitingRetry: return "配置已保存，等待重试"
        case .failed: return "操作失败"
        }
    }

    var color: Color {
        switch self {
        case .ready: return HermesChatPalette.green
        case .streaming, .loadingSession, .connecting, .recovering, .stopping: return HermesChatPalette.blue
        case .awaitingInput, .providerConfigurationSavedAwaitingRetry: return .orange
        case .configurationRequired, .failed: return HermesChatPalette.coral
        case .disconnected, .interrupted: return HermesChatPalette.muted
        }
    }
}

extension ToolActivityStatus {
    var label: String {
        switch self {
        case .running: return "运行中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        }
    }

    var color: Color {
        switch self {
        case .running: return HermesChatPalette.blue
        case .completed: return HermesChatPalette.green
        case .failed: return HermesChatPalette.coral
        case .interrupted: return .orange
        }
    }
}
