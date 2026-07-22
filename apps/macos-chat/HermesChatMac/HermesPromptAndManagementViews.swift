import AppKit
import SwiftUI

struct HermesPromptSheet: View {
    @EnvironmentObject private var chat: HermesChatStore
    @Environment(\.dismiss) private var dismiss
    let request: ApprovalRequest
    @State private var value = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text("请确认内容后再响应；关闭或取消按拒绝处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("请求内容") {
                    Text(request.prompt)
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .font(request.kind == "approval.request" ? .body.monospaced() : .caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityLabel(
                                request.kind == "approval.request"
                                    ? "待批准命令：\(detail)"
                                    : "请求字段：\(detail)"
                            )
                    }
                }

                if request.kind == "secret.request" || request.kind == "sudo.request" {
                    Section("安全输入") {
                        SecureField(
                            request.kind == "sudo.request" ? "输入 sudo 密码" : "输入敏感内容",
                            text: $value
                        )
                        .accessibilityIdentifier("mac.prompt.secret")
                        Text("输入内容不会显示在 transcript 中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if request.kind == "clarify.request" {
                    Section("你的回答") {
                        ForEach(request.choices, id: \.self) { choice in
                            Button {
                                value = choice
                            } label: {
                                HStack {
                                    Text(choice)
                                    Spacer()
                                    if value == choice { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                        TextField("输入回答", text: $value, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("mac.prompt.clarify")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("取消") { reject() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mac.prompt.cancel")
                Button("拒绝") { reject() }
                    .accessibilityIdentifier("mac.prompt.reject")
                Spacer()
                Button(actionTitle) {
                    Task {
                        await chat.respond(
                            to: request,
                            accepted: true,
                            value: value.isEmpty ? nil : value
                        )
                        value = ""
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("mac.prompt.approve")
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.prompt.root", label: "Hermes Chat 请求页面")
        }
    }

    private var title: String {
        switch request.kind {
        case "approval.request": return "Hermes 请求执行操作"
        case "clarify.request": return "Hermes 需要澄清"
        case "sudo.request": return "Hermes 需要 sudo 授权"
        default: return "Hermes 需要安全输入"
        }
    }

    private var actionTitle: String {
        request.kind == "approval.request" ? "允许一次" : "提交"
    }

    private func reject() {
        Task {
            await chat.respond(to: request, accepted: false)
            value = ""
            dismiss()
        }
    }
}

struct HermesManagementCenter: View {
    enum Module: String, CaseIterable, Identifiable {
        case connection = "连接"
        case provider = "Provider"
        case sessions = "Session"
        case autostart = "自动启动"
        case logs = "日志"
        case search = "高级搜索"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .connection: return "link"
            case .provider: return "cpu"
            case .sessions: return "rectangle.stack"
            case .autostart: return "power"
            case .logs: return "doc.text.magnifyingglass"
            case .search: return "sparkle.magnifyingglass"
            }
        }
        var accessibilityID: String {
            switch self {
            case .connection: return "mac.management.connection"
            case .provider: return "mac.management.provider"
            case .sessions: return "mac.management.sessions"
            case .autostart: return "mac.management.autostart"
            case .logs: return "mac.management.logs"
            case .search: return "mac.management.search"
            }
        }
    }

    @EnvironmentObject private var runtime: HermesChatRuntime
    @EnvironmentObject private var chat: HermesChatStore
    @Environment(\.dismiss) private var dismiss
    @Binding var showingConnection: Bool
    @Binding var showingProviderSetup: Bool
    @State private var selection: Module = .connection
    @State private var searchText = ""
    @State private var logText = ""
    @AppStorage(
        HermesChatIdentity.autoStartLocalHermesKey,
        store: HermesChatIdentity.defaults
    ) private var autoStartLocalHermes = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("高级功能中心").font(.title2.bold())
                    Text("管理 Chat 自身能力；不会打开或依赖 Hermes Admin。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mac.management.close")
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
                List(Module.allCases, selection: $selection) { module in
                    Label(module.rawValue, systemImage: module.symbol)
                        .tag(module)
                        .accessibilityIdentifier(module.accessibilityID)
                }
                .listStyle(.sidebar)
                .frame(width: 190)

                Divider()

                ScrollView {
                    moduleContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                }
            }
        }
        .frame(width: 820, height: 620)
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.management.root", label: "Hermes Chat 高级功能中心")
        }
        .onChange(of: selection) { _, value in
            if value == .logs { refreshLogs() }
            if value == .sessions { Task { await chat.refreshSessions() } }
        }
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch selection {
        case .connection:
            moduleHeader("连接", detail: "管理本机 owned backend 或远程 Hermes 连接。")
            LabeledContent("当前状态", value: runtime.state.label)
            if !runtime.statusDetail.isEmpty { Text(runtime.statusDetail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("打开连接设置") {
                    dismiss()
                    showingConnection = true
                }
                .buttonStyle(.borderedProminent)
                Button("断开") { runtime.stop() }
                    .disabled(runtime.state == .idle)
            }

        case .provider:
            moduleHeader("Provider", detail: "读取 Hermes 的 Provider、凭据状态和模型列表。")
            LabeledContent("Provider", value: chat.providerOptions?.provider ?? "未读取")
            LabeledContent("模型", value: chat.providerOptions?.model ?? "未读取")
            HStack {
                Button("刷新") { Task { await chat.loadProviderSetup(refresh: true) } }
                Button("配置服务") {
                    dismiss()
                    showingProviderSetup = true
                }
                .buttonStyle(.borderedProminent)
            }

        case .sessions:
            moduleHeader("Session", detail: "Hermes backend 是唯一事实源。")
            Button("新建会话") { Task { await chat.createSession() } }
                .buttonStyle(.borderedProminent)
            ForEach(chat.sessions) { session in
                Button {
                    Task { await chat.selectSession(session.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(session.title)
                            Text(session.preview).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if chat.activeStoredSessionID == session.id { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }

        case .autostart:
            moduleHeader("自动启动", detail: "只控制 Hermes Chat 创建的本机 headless backend。")
            Toggle("App 启动时自动启动本机 Hermes", isOn: $autoStartLocalHermes)
            Text("关闭后不会停止当前 backend；下一次启动生效。任何情况下都不会停止用户已有 Dashboard、Gateway 或 Hermes Admin。")
                .font(.caption).foregroundStyle(.secondary)

        case .logs:
            moduleHeader("日志", detail: "只显示 Hermes Chat owned backend 的本地日志。")
            HStack {
                Button("刷新日志", action: refreshLogs)
                if let url = runtime.processController.logURL {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Text(logText.isEmpty ? "暂无 owned backend 日志" : logText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

        case .search:
            moduleHeader("高级搜索", detail: "在 Hermes 返回的 Session 标题和摘要中即时筛选。")
            TextField("搜索会话", text: $searchText)
                .textFieldStyle(.roundedBorder)
            let matches = chat.sessions.filter {
                searchText.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.preview.localizedCaseInsensitiveContains(searchText)
            }
            Text("\(matches.count) 个结果").font(.caption).foregroundStyle(.secondary)
            ForEach(matches) { session in
                Button {
                    Task { await chat.selectSession(session.id); dismiss() }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                        Text(session.preview).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func moduleHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
        }
    }

    private func refreshLogs() {
        logText = runtime.processController.recentLog(maxBytes: 40_000)
    }
}
