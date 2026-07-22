import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedSheet: IOSWorkspaceSheet?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            chatWorkspace
                .navigationTitle("Hermes Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .tint(Color(red: 0.12, green: 0.44, blue: 0.94))
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection:
                IOSConnectionSheet(showProviderSetup: providerSheetBinding)
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
            case .sessions:
                sessionSheet
            case .provider:
                IOSProviderSetupSheet()
                    .environmentObject(store)
            case .tools:
                IOSToolActivitySheet()
                    .environmentObject(store)
            }
        }
        .sheet(item: $store.pendingApproval) { request in
            ApprovalSheet(request: request) { accepted, value in
                Task { await store.respond(to: request, accepted: accepted, value: value) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !store.serverText.isEmpty, store.state != .ready else { return }
            Task { await store.reconnect() }
        }
        .alert(
            "Hermes 操作失败",
            isPresented: Binding(
                get: { store.operationError != nil },
                set: { if !$0 { store.clearOperationError() } }
            )
        ) {
            Button("好") { store.clearOperationError() }
        } message: {
            Text(store.operationError ?? "未知错误")
                .accessibilityIdentifier("ios.chat.error")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { presentedSheet = .sessions } label: {
                Label("会话", systemImage: "bubble.left.and.bubble.right")
            }
            .accessibilityIdentifier("ios.chat.sessions")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { presentedSheet = .connection } label: {
                Image(systemName: store.state == .ready ? "link.circle.fill" : "link.badge.plus")
            }
            .accessibilityLabel("连接 Hermes")
            .accessibilityIdentifier("ios.chat.connection")

            Menu {
                Button("配置 Provider", systemImage: "cpu") { presentedSheet = .provider }
                    .disabled(store.state != .ready)
                Button("工具活动", systemImage: "hammer") { presentedSheet = .tools }
                Button("刷新会话", systemImage: "arrow.clockwise") { Task { await store.refreshSessions() } }
                    .disabled(store.state != .ready)
                Divider()
                Button("断开", systemImage: "xmark.circle") { store.disconnect() }
                    .disabled(store.state == .disconnected)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("高级功能")
            .accessibilityIdentifier("ios.chat.advanced")
        }
    }

    private var chatWorkspace: some View {
        VStack(spacing: 0) {
            statusStrip
            providerRecovery
            toolSummary
            transcript
            Divider()
            composer
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.98, blue: 1.00),
                    Color(red: 1.00, green: 0.97, blue: 0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                AccessibilityPageMarker(identifier: "ios.chat.root", label: "Hermes Chat 页面")
                AccessibilityPageMarker(
                    identifier: "ios.sheet.state",
                    label: "当前 Sheet：\(presentedSheet?.rawValue ?? "none")"
                )
                AccessibilityPageMarker(
                    identifier: "ios.session.active",
                    label: "当前 Session：\(EvidenceIdentifier.sha256(store.activeSessionID ?? "none"))"
                )
                AccessibilityPageMarker(
                    identifier: "ios.session.stored",
                    label: "持久 Session：\(EvidenceIdentifier.sha256(store.activeStoredSessionID ?? "none"))"
                )
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(store.state.color).frame(width: 8, height: 8)
            Text(store.state.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.state.color)
                .accessibilityIdentifier("ios.chat.connection.state")
            Text("· \(store.workspacePhase.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ios.chat.workspace.phase")
            Spacer()
            if store.state != .ready {
                Button("连接") { presentedSheet = .connection }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("ios.connection.open")
            }
            if store.isStreaming {
                Button("停止", systemImage: "stop.circle") { Task { await store.stop() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("ios.chat.stop.top")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var providerRecovery: some View {
        if let presentation = store.providerRecoveryPresentation(platform: .iOS) {
            IOSProviderRecoveryCard(
                presentation: presentation,
                configure: { presentedSheet = .provider },
                cancel: { store.cancelProviderConfiguration() }
            )
        } else if let saved = store.providerConfigurationSavedPresentation(platform: .iOS) {
            VStack(alignment: .leading, spacing: 9) {
                Label(saved.title, systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
                Text(saved.summary).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(saved.cancelActionTitle) { store.cancelProviderConfiguration() }
                        .accessibilityIdentifier("ios.provider.cancel")
                    Spacer()
                    Button(saved.retryActionTitle) { Task { await store.retryProviderRequest() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.provider.retry")
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.09))
        }
    }

    @ViewBuilder
    private var toolSummary: some View {
        if let activity = store.toolActivities.last {
            HStack(spacing: 10) {
                Image(systemName: activity.status.systemImage)
                    .foregroundStyle(activity.status.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.name).font(.caption.weight(.semibold))
                    Text(activity.summary.isEmpty ? activity.context : activity.summary)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(activity.status.label).font(.caption2).foregroundStyle(activity.status.color)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { presentedSheet = .tools }
            .background(Color.white.opacity(0.72))
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("ios.tools.summary")
            .accessibilityLabel("工具活动 \(activity.name)")
            .accessibilityValue(
                "\(activity.status.label)，\(activity.summary.isEmpty ? activity.context : activity.summary)"
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { presentedSheet = .tools }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if visibleMessages.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(Color(red: 0.12, green: 0.44, blue: 0.94))
                            Text("从聊天开始工作").font(.title2.bold())
                            Text(store.state == .ready ? "输入第一条消息开始工作" : "连接 Hermes 后，会话、工具和结果都会显示在这里")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if store.state != .ready {
                                Button("连接 Hermes") { presentedSheet = .connection }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 72)
                    }
                    ForEach(visibleMessages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("ios.chat.transcript")
            .onChange(of: visibleMessages.count) { _, _ in
                if let last = visibleMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var visibleMessages: [ChatMessage] {
        store.messages.filter { message in
            guard let error = message.error else { return true }
            return ProviderSetupErrorClassifier.classify(error) == nil
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("告诉 Hermes 你想完成什么…", text: $store.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($composerFocused)
                .accessibilityIdentifier("ios.chat.composer")
            if composerFocused {
                Button { composerFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel("收起键盘")
                .accessibilityIdentifier("ios.chat.keyboard.dismiss")
            }
            if store.isStreaming {
                Button { Task { await store.stop() } } label: {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
                .accessibilityLabel("停止生成")
                .accessibilityIdentifier("ios.chat.stop")
            } else {
                Button { Task { await store.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(
                    store.state != .ready
                        || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("发送消息")
                .accessibilityIdentifier("ios.chat.send")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var sessionSheet: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "还没有会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(store.state == .ready ? "点击新建开始工作" : "连接 Hermes 后加载会话")
                    )
                } else {
                    List(store.sessions) { session in
                        Button {
                            Task {
                                await store.selectSession(session.id)
                                presentedSheet = nil
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(session.title)
                                Text(session.preview).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("session.row.\(EvidenceIdentifier.sha256(session.id))")
                    }
                    .accessibilityIdentifier("ios.session.list")
                }
            }
            .navigationTitle("会话")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { presentedSheet = nil }
                        .accessibilityIdentifier("ios.session.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("新建") {
                        Task { await store.createSession(); presentedSheet = nil }
                    }
                    .disabled(store.state != .ready)
                    .accessibilityIdentifier("ios.session.new")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.sessions.root", label: "Hermes 会话页面")
        }
        .task { if store.state == .ready { await store.refreshSessions() } }
    }

    private var providerSheetBinding: Binding<Bool> {
        Binding(
            get: { presentedSheet == .provider },
            set: { isPresented in
                if isPresented {
                    presentedSheet = .provider
                } else if presentedSheet == .provider {
                    presentedSheet = nil
                }
            }
        )
    }
}

private enum IOSWorkspaceSheet: String, Identifiable {
    case connection
    case sessions
    case provider
    case tools

    var id: String { rawValue }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == "user" ? "你" : "Hermes")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text.isEmpty && message.isStreaming ? "正在思考…" : message.text)
                    .textSelection(.enabled)
                if let error = message.error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding(12)
            .background(
                message.role == "user" ? Color.blue.opacity(0.12) : Color.white.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 14)
            )
            if message.role != "user" { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.\(message.role).\(EvidenceIdentifier.sha256(message.id))")
        .accessibilityLabel(
            "\(message.role == "user" ? "用户" : "Hermes")消息：\(message.text)"
                + (message.error.map { "，错误：\($0)" } ?? "")
        )
    }
}

private struct ApprovalSheet: View {
    let request: ApprovalRequest
    let respond: (Bool, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("需要你的响应") {
                    Text(request.prompt)
                    if let detail = request.detail, !detail.isEmpty {
                        Text(detail)
                            .font(request.kind == "approval.request" ? .system(.body, design: .monospaced) : .footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if request.kind == "secret.request" || request.kind == "sudo.request" {
                        SecureField(request.kind == "sudo.request" ? "输入 sudo 密码" : "输入敏感内容", text: $value)
                            .textContentType(.password)
                            .accessibilityIdentifier("ios.prompt.secret")
                    } else if request.kind == "clarify.request" {
                        ForEach(request.choices, id: \.self) { choice in
                            Button { value = choice } label: {
                                HStack { Text(choice); Spacer(); if value == choice { Image(systemName: "checkmark.circle.fill") } }
                            }
                        }
                        TextField("输入回答", text: $value, axis: .vertical)
                            .lineLimit(2...6)
                            .accessibilityIdentifier("ios.prompt.clarify")
                    }
                }
                Section {
                    Button("取消") { respond(false, nil); dismiss() }
                        .accessibilityIdentifier("ios.prompt.cancel")
                    Button("拒绝") { respond(false, nil); dismiss() }
                        .accessibilityIdentifier("ios.prompt.reject")
                    Button("允许 / 提交") { respond(true, value.isEmpty ? nil : value); value = ""; dismiss() }
                        .accessibilityIdentifier("ios.prompt.approve")
                }
            }
            .navigationTitle("Hermes 请求")
        }
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.prompt.root", label: "Hermes 请求页面")
        }
    }
}

struct AccessibilityPageMarker: View {
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

extension GatewayConnectionState {
    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .ready: return "在线"
        case .failed(let message): return "失败：\(message)"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}

extension ChatWorkspacePhase {
    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .ready: return "就绪"
        case .loadingSession: return "加载会话"
        case .streaming: return "回复中"
        case .stopping: return "停止中"
        case .interrupted: return "已停止"
        case .awaitingInput: return "等待输入"
        case .recovering: return "恢复中"
        case .configurationRequired: return "需要配置服务"
        case .providerConfigurationSavedAwaitingRetry: return "等待重试"
        case .failed: return "操作失败"
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
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .orange
        }
    }

    var systemImage: String {
        switch self {
        case .running: return "hammer.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .interrupted: return "stop.circle.fill"
        }
    }
}
