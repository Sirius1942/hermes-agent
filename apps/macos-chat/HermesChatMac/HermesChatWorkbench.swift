import SwiftUI

struct HermesChatWorkbench: View {
    @EnvironmentObject private var runtime: HermesChatRuntime
    @EnvironmentObject private var chat: HermesChatStore
    @State private var inspectorVisible = true
    @State private var showingConnection = false
    @State private var showingProviderSetup = false
    @State private var showingManagement = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                HermesSessionSidebar()
                    .frame(width: geometry.size.width < 980 ? 220 : 260)

                Divider()

                chatColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if inspectorVisible && geometry.size.width >= 1040 {
                    Divider()
                    HermesInspector()
                        .frame(width: 320)
                }
            }
            .background(workspaceBackground)
        }
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.workbench.root", label: "Hermes Chat macOS 工作台")
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showingConnection) {
            HermesConnectionSheet(showProviderSetup: $showingProviderSetup)
                .environmentObject(runtime)
                .environmentObject(chat)
        }
        .sheet(isPresented: $showingProviderSetup) {
            HermesProviderSetupSheet()
                .environmentObject(chat)
        }
        .sheet(isPresented: $showingManagement) {
            HermesManagementCenter(
                showingConnection: $showingConnection,
                showingProviderSetup: $showingProviderSetup
            )
            .environmentObject(runtime)
            .environmentObject(chat)
        }
        .sheet(item: $chat.pendingApproval) { request in
            HermesPromptSheet(request: request)
                .environmentObject(chat)
        }
        .alert(
            "Hermes 操作失败",
            isPresented: Binding(
                get: { chat.operationError != nil },
                set: { if !$0 { chat.clearOperationError() } }
            )
        ) {
            Button("好") { chat.clearOperationError() }
        } message: {
            Text(chat.operationError ?? "未知错误")
        }
    }

    private var workspaceBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.94, green: 0.98, blue: 1.00),
                Color(red: 1.00, green: 0.96, blue: 0.91),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            connectionBanner
            providerRecovery
            transcript
            Divider()
            composer
        }
        .background(Color.white.opacity(0.62))
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if runtime.state.isConnectionReady {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                Image(systemName: runtime.state.symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(runtime.state.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(runtime.state.label).font(.headline)
                    Text(runtime.statusDetail.isEmpty ? "连接本地或远程 Hermes 后即可开始工作。" : runtime.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("连接 Hermes") { showingConnection = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.connection.open")
            }
            .padding(14)
            .background(runtime.state.color.opacity(0.08))
        }
    }

    @ViewBuilder
    private var providerRecovery: some View {
        if let presentation = chat.providerRecoveryPresentation(platform: .macOS) {
            HermesProviderRecoveryCard(
                title: presentation.title,
                summary: presentation.summary,
                diagnostic: presentation.diagnostic,
                configure: { showingProviderSetup = true },
                cancel: { chat.cancelProviderConfiguration() }
            )
        } else if let saved = chat.providerConfigurationSavedPresentation(platform: .macOS) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(HermesChatPalette.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(saved.title).font(.headline)
                    Text(saved.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(saved.cancelActionTitle) { chat.cancelProviderConfiguration() }
                    .accessibilityIdentifier("mac.provider.cancel")
                Button(saved.retryActionTitle) { Task { await chat.retryProviderRequest() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.provider.retry")
            }
            .padding(14)
            .background(HermesChatPalette.green.opacity(0.09))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        HermesWelcomeView(
                            isReady: chat.state == .ready,
                            connect: { showingConnection = true },
                            createSession: { Task { await chat.createSession() } }
                        )
                            .padding(.top, 50)
                    }
                    ForEach(chat.messages) { message in
                        HermesMessageRow(message: message).id(message.id)
                    }
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .accessibilityIdentifier("mac.chat.transcript")
            .onChange(of: chat.messages.count) { _, _ in
                if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("告诉 Hermes 你想完成什么…", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($composerFocused)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(HermesChatPalette.blue.opacity(0.22))
                }
                .accessibilityIdentifier("mac.chat.composer")
                .onSubmit {
                    guard !chat.isStreaming else { return }
                    Task { await chat.send() }
                }

            if chat.isStreaming {
                Button { Task { await chat.stop() } } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(HermesChatPalette.coral)
                .accessibilityIdentifier("mac.chat.stop")
            } else {
                Button { Task { await chat.send() } } label: {
                    Label("发送", systemImage: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    chat.state != .ready
                        || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("mac.chat.send")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Label("Hermes Chat", systemImage: "sparkles.rectangle.stack.fill")
                .font(.headline)
            HermesStatusPill(
                title: runtime.state.label,
                color: runtime.state.color,
                systemImage: runtime.state.symbol
            )
            .accessibilityIdentifier("mac.connection.status")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await chat.createSession() } } label: {
                Label("新建会话", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("mac.session.new")
            .disabled(chat.state != .ready)

            Button { inspectorVisible.toggle() } label: {
                Label("检查器", systemImage: "sidebar.right")
            }
            .help("显示或隐藏运行状态、工具和 Diff")

            Button { showingManagement = true } label: {
                Label("高级功能中心", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("mac.management.open")
        }
    }
}

private struct HermesWelcomeView: View {
    let isReady: Bool
    let connect: () -> Void
    let createSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(HermesChatPalette.blue.opacity(0.12)).frame(width: 86, height: 86)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(HermesChatPalette.blue)
            }
            Text("从聊天开始工作").font(.largeTitle.bold())
            Text("Hermes Chat 把会话、工具活动、Diff 和运行状态放在同一个原生工作台中。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button(isReady ? "新建会话" : "连接 Hermes", action: isReady ? createSession : connect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(isReady ? "mac.welcome.new-session" : "mac.welcome.connect")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HermesMessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == "user" { Spacer(minLength: 80) }
            if message.role != "user" {
                Image(systemName: "sparkles")
                    .frame(width: 30, height: 30)
                    .background(HermesChatPalette.blue.opacity(0.12), in: Circle())
                    .foregroundStyle(HermesChatPalette.blue)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(message.role == "user" ? "你" : "Hermes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.text.isEmpty && message.isStreaming ? "正在思考…" : message.text)
                    .textSelection(.enabled)
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(HermesChatPalette.coral)
                }
            }
            .padding(14)
            .background(
                message.role == "user"
                    ? HermesChatPalette.blue.opacity(0.11)
                    : Color.white.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            if message.role != "user" { Spacer(minLength: 80) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.\(message.role).\(EvidenceIdentifier.sha256(message.id))")
        .accessibilityLabel("\(message.role == "user" ? "用户" : "Hermes")消息：\(message.text)")
    }
}

private struct HermesProviderRecoveryCard: View {
    let title: String
    let summary: String
    let diagnostic: String
    let configure: () -> Void
    let cancel: () -> Void
    @State private var diagnosticsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundStyle(HermesChatPalette.coral)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: cancel)
                    .accessibilityIdentifier("mac.provider.cancel")
                Button("配置服务", action: configure)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.provider.configure")
            }
            DisclosureGroup("原始诊断", isExpanded: $diagnosticsExpanded) {
                Text(diagnostic)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            .accessibilityIdentifier("mac.provider.diagnostics")
        }
        .padding(14)
        .background(HermesChatPalette.coral.opacity(0.08))
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.provider.recovery", label: "Hermes Provider 恢复卡")
        }
    }
}

struct HermesSessionSidebar: View {
    @EnvironmentObject private var chat: HermesChatStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("会话").font(.headline)
                Spacer()
                Button { Task { await chat.createSession() } } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mac.session.new")
                .disabled(chat.state != .ready)
            }
            .padding(14)

            Divider()

            if chat.sessions.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(chat.state == .ready ? "新建会话开始工作" : "连接 Hermes 后加载会话")
                )
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("mac.session.list")
            } else {
                List(chat.sessions, selection: Binding(
                    get: { chat.activeStoredSessionID },
                    set: { value in if let value { Task { await chat.selectSession(value) } } }
                )) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title).lineLimit(1)
                        Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(session.id)
                    .accessibilityIdentifier("session.row.\(EvidenceIdentifier.sha256(session.id))")
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("mac.session.list")
            }
        }
        .background(Color.white.opacity(0.78))
        .task {
            if chat.state == .ready { await chat.refreshSessions() }
        }
    }
}

struct HermesInspector: View {
    @EnvironmentObject private var runtime: HermesChatRuntime
    @EnvironmentObject private var chat: HermesChatStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorSection("运行状态", systemImage: "waveform.path.ecg") {
                    HermesStatusPill(
                        title: chat.workspacePhase.label,
                        color: chat.workspacePhase.color,
                        systemImage: "circle.fill"
                    )
                    if !runtime.statusDetail.isEmpty {
                        Text(runtime.statusDetail).font(.caption).foregroundStyle(.secondary)
                    }
                }

                inspectorSection("工具活动", systemImage: "hammer") {
                    if chat.toolActivities.isEmpty {
                        Text("当前没有工具活动").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(chat.toolActivities.suffix(8)) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(activity.name).font(.caption.weight(.semibold))
                                Spacer()
                                Text(activity.status.label).font(.caption2).foregroundStyle(activity.status.color)
                            }
                            if !activity.summary.isEmpty { Text(activity.summary).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }

                inspectorSection("Diff", systemImage: "plus.forwardslash.minus") {
                    if let diff = chat.toolActivities.reversed().compactMap(\.inlineDiff).first {
                        Text(diff).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("尚无 Diff").font(.caption).foregroundStyle(.secondary)
                    }
                }

                inspectorSection("Session", systemImage: "rectangle.stack") {
                    Text(chat.activeStoredSessionID ?? chat.activeSessionID ?? "尚未选择")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                inspectorSection("模型 / 费用", systemImage: "cpu") {
                    Text(chat.providerOptions?.provider ?? "由 Hermes 选择 Provider").font(.caption)
                    Text(chat.providerOptions?.model ?? "由 Hermes 选择模型").font(.caption).foregroundStyle(.secondary)
                    Text("费用以 Hermes backend 记录为准").font(.caption2).foregroundStyle(.secondary)
                }

                DisclosureGroup("诊断") {
                    Text(runtime.backend.statusDetail.isEmpty ? "无额外诊断" : runtime.backend.statusDetail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
            }
            .padding(16)
        }
        .background(Color.white.opacity(0.82))
        .accessibilityIdentifier("mac.inspector.root")
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 12))
    }
}
