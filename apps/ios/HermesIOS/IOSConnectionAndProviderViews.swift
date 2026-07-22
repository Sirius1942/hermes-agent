import SwiftUI

struct IOSConnectionSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Binding var showProviderSetup: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("连接 Hermes") {
                    TextField("服务器地址，例如 https://…", text: $store.serverText)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("ios.connection.url")
                    SecureField("Token（保存到 Keychain）", text: $store.tokenText)
                        .accessibilityIdentifier("ios.connection.token")
                    HStack {
                        Circle().fill(store.state.color).frame(width: 9, height: 9)
                        Text(store.state.label).foregroundStyle(.secondary)
                    }
                    Button("连接并返回 Chat") {
                        Task {
                            await store.connect()
                            if store.state == .ready { dismiss() }
                        }
                    }
                    .accessibilityIdentifier("ios.connection.connect")
                    .buttonStyle(.borderedProminent)
                    .disabled(store.serverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("服务配置") {
                    Button("配置 Provider") {
                        dismiss()
                        showProviderSetup = true
                    }
                    .disabled(store.state != .ready)
                    .accessibilityIdentifier("ios.provider.configure")
                    if let error = store.providerSetupError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Text("iOS 只连接远程或局域网可达的 Hermes，不在手机上启动 backend。连接失败不会清空当前 Session、历史或草稿。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("连接与服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("ios.connection.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重试") { Task { await store.reconnect() } }
                        .disabled(store.serverText.isEmpty)
                        .accessibilityIdentifier("ios.connection.retry")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.connection.root", label: "Hermes 连接页面")
        }
    }
}

struct IOSProviderRecoveryCard: View {
    let presentation: ProviderRecoveryPresentation
    let configure: () -> Void
    let cancel: () -> Void
    @State private var diagnosticsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(presentation.title, systemImage: "bolt.horizontal.circle.fill")
                .font(.headline).foregroundStyle(.red)
            Text(presentation.summary).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("原始诊断", isExpanded: $diagnosticsExpanded) {
                Text(presentation.diagnostic)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.top, 5)
            }
            .accessibilityIdentifier("ios.provider.diagnostics")
            HStack {
                Button(presentation.cancelActionTitle, action: cancel)
                    .accessibilityIdentifier("ios.provider.cancel")
                Spacer()
                Button(presentation.configureActionTitle, action: configure)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ios.provider.configure")
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.07))
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.provider.recovery", label: "Hermes Provider 恢复卡")
        }
    }
}

struct IOSProviderSetupSheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider = ""
    @State private var selectedModel = ""
    @State private var selectedCredentialKey = ""
    @State private var credentialValue = ""
    @State private var validationMessage = ""
    @State private var confirmExpensiveModel = false

    private var providers: [HermesProviderOption] { store.providerOptions?.providers ?? [] }
    private var selectedProviderOption: HermesProviderOption? {
        providers.first(where: { $0.slug == selectedProvider })
    }
    private var credentialKeys: [(key: String, value: HermesEnvironmentVariable)] {
        store.providerEnvironment
            .filter { _, value in
                !value.advanced && (
                    value.provider == selectedProvider
                        || value.provider?.lowercased() == selectedProvider.lowercased()
                )
            }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider 与模型") {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("请选择").tag("")
                        ForEach(providers) { Text($0.name).tag($0.slug) }
                    }
                    .accessibilityIdentifier("ios.provider.provider-picker")
                    .onChange(of: selectedProvider) { _, value in
                        selectedModel = providers.first(where: { $0.slug == value })?.models.first ?? ""
                        selectedCredentialKey = credentialKeys.first?.key ?? ""
                        credentialValue = ""
                    }
                    Picker("模型", selection: $selectedModel) {
                        Text("请选择").tag("")
                        ForEach(selectedProviderOption?.models ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("ios.provider.model-picker")
                }

                if !credentialKeys.isEmpty {
                    Section("安全凭据") {
                        Picker("配置项", selection: $selectedCredentialKey) {
                            ForEach(credentialKeys, id: \.key) { item in
                                Text(item.value.providerLabel ?? item.key).tag(item.key)
                            }
                        }
                        SecureField("输入凭据", text: $credentialValue)
                            .textContentType(.password)
                            .accessibilityIdentifier("ios.provider.credential")
                        if let selected = store.providerEnvironment[selectedCredentialKey] {
                            Text(selected.description).font(.caption).foregroundStyle(.secondary)
                            if selected.isSet { Label("Hermes 本地已配置", systemImage: "checkmark.shield.fill").foregroundStyle(.green) }
                        }
                        Button("验证凭据") {
                            Task {
                                let result = await store.validateProviderCredential(
                                    key: selectedCredentialKey,
                                    value: credentialValue
                                )
                                validationMessage = result?.message ?? store.providerSetupError ?? "验证未返回结果"
                            }
                        }
                        .disabled(selectedCredentialKey.isEmpty || credentialValue.isEmpty || store.isProviderSetupBusy)
                    }
                }

                Section("保存") {
                    Toggle("确认使用可能产生额外费用的模型", isOn: $confirmExpensiveModel)
                    Button("保存并等待明确重试") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedProvider.isEmpty || selectedModel.isEmpty || store.isProviderSetupBusy)
                        .accessibilityIdentifier("ios.provider.save")
                    Text("保存不会自动重发上一条消息。返回原 Session 后，由你点击“重新尝试”。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if store.isProviderSetupBusy { ProgressView("正在读取 Hermes 配置…") }
                if !validationMessage.isEmpty { Text(validationMessage).font(.caption) }
                if let error = store.providerSetupError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("配置模型服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        credentialValue = ""
                        store.cancelProviderConfiguration()
                        dismiss()
                    }
                    .accessibilityIdentifier("ios.provider.cancel")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.provider.root", label: "Hermes Provider 配置页面")
        }
        .task {
            await store.loadProviderSetup()
            selectedProvider = store.providerOptions?.provider
                ?? providers.first(where: { $0.isCurrent == true })?.slug
                ?? providers.first?.slug
                ?? ""
            selectedModel = store.providerOptions?.model
                ?? providers.first(where: { $0.slug == selectedProvider })?.models.first
                ?? ""
            selectedCredentialKey = credentialKeys.first?.key ?? ""
        }
    }

    private func save() async {
        if !selectedCredentialKey.isEmpty, !credentialValue.isEmpty {
            guard await store.saveProviderCredential(
                key: selectedCredentialKey,
                value: credentialValue
            ) else { return }
        }
        let assignment = await store.selectMainModel(
            provider: selectedProvider,
            model: selectedModel,
            confirmExpensiveModel: confirmExpensiveModel
        )
        credentialValue = ""
        if assignment?.ok == true { dismiss() }
    }
}

struct IOSToolActivitySheet: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.toolActivities.isEmpty {
                    ContentUnavailableView("暂无工具活动", systemImage: "hammer")
                } else {
                    List(store.toolActivities.reversed()) { activity in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(activity.name).font(.headline)
                                Spacer()
                                Text(activity.status.label).font(.caption).foregroundStyle(activity.status.color)
                            }
                            if !activity.context.isEmpty {
                                Text(activity.context).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if !activity.summary.isEmpty { Text(activity.summary).font(.callout) }
                            if let diff = activity.inlineDiff {
                                DisclosureGroup("Diff") {
                                    Text(diff).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                .accessibilityIdentifier(
                                    "ios.tools.diff.\(EvidenceIdentifier.sha256(activity.id))"
                                )
                            }
                        }
                        .padding(.vertical, 5)
                        .accessibilityIdentifier(
                            "ios.tools.row.\(EvidenceIdentifier.sha256(activity.id))"
                        )
                    }
                }
            }
            .navigationTitle("工具活动")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("ios.tools.close")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            AccessibilityPageMarker(identifier: "ios.tools.root", label: "Hermes 工具活动页面")
        }
    }
}
