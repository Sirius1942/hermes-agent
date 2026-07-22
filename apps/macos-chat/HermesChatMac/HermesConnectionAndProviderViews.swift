import SwiftUI

struct HermesConnectionSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case local = "本机"
        case remote = "远程"
        var id: String { rawValue }
    }

    @EnvironmentObject private var runtime: HermesChatRuntime
    @EnvironmentObject private var chat: HermesChatStore
    @Environment(\.dismiss) private var dismiss
    @Binding var showProviderSetup: Bool
    @State private var mode: Mode = .local
    @AppStorage(
        HermesChatIdentity.localHermesExecutablePathKey,
        store: HermesChatIdentity.defaults
    ) private var executablePath = ""
    @State private var remoteURL = ""
    @State private var remoteToken = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接 Hermes").font(.title2.bold())
                    Text("Chat 直接连接 headless backend，不加载 Dashboard。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .accessibilityIdentifier("mac.connection.cancel")
            }
            .padding(20)

            Divider()

            Form {
                Picker("连接方式", selection: $mode) {
                    ForEach(Mode.allCases) { option in
                        Text(option.rawValue)
                            .tag(option)
                            .accessibilityIdentifier(
                                option == .local
                                    ? "mac.connection.mode.local"
                                    : "mac.connection.mode.remote"
                            )
                    }
                }
                .pickerStyle(.segmented)

                if mode == .local {
                    Section("本机 Hermes") {
                        TextField("hermes 可执行文件路径（可留空自动查找）", text: $executablePath)
                            .accessibilityIdentifier("mac.connection.local.path")
                        Text("优先连接同一 profile 的 Gateway；否则启动 app 自有的本机 backend。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("启动本机 Hermes") {
                            Task {
                                await runtime.startLocal(preferredExecutablePath: executablePath)
                                if runtime.state.isLocalConnectionReady { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mac.connection.local")
                    }
                } else {
                    Section("远程 Hermes") {
                        TextField("https://或 http://服务器地址", text: $remoteURL)
                            .accessibilityIdentifier("mac.connection.remote.url")
                        SecureField("连接 Token", text: $remoteToken)
                            .accessibilityIdentifier("mac.connection.remote.token")
                        Button("连接远程 Hermes") {
                            Task {
                                guard let url = URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                                await runtime.connectRemote(serverURL: url, token: remoteToken)
                                remoteToken = ""
                                if case .readyRemote = runtime.state { dismiss() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(URL(string: remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                        .accessibilityIdentifier("mac.connection.remote")
                    }
                }

                Section("当前状态") {
                    LabeledContent("连接", value: runtime.state.label)
                    if !runtime.statusDetail.isEmpty {
                        Text(runtime.statusDetail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("重试") {
                            Task {
                                if mode == .local {
                                    await runtime.startLocal(preferredExecutablePath: executablePath)
                                } else if let url = URL(string: remoteURL) {
                                    await runtime.connectRemote(serverURL: url, token: remoteToken)
                                }
                            }
                        }
                        .accessibilityIdentifier("mac.connection.retry")
                        Button("配置 Provider") {
                            dismiss()
                            showProviderSetup = true
                        }
                        .disabled(chat.state != .ready)
                        .accessibilityIdentifier("mac.provider.configure")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 560)
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.connection.root", label: "Hermes Chat 连接页面")
        }
    }
}

struct HermesProviderSetupSheet: View {
    @EnvironmentObject private var chat: HermesChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider = ""
    @State private var selectedModel = ""
    @State private var selectedCredentialKey = ""
    @State private var credentialValue = ""
    @State private var validationMessage = ""
    @State private var confirmExpensiveModel = false

    private var providers: [HermesProviderOption] {
        chat.providerOptions?.providers ?? []
    }

    private var selectedProviderOption: HermesProviderOption? {
        providers.first(where: { $0.slug == selectedProvider })
    }

    private var credentialKeys: [(key: String, value: HermesEnvironmentVariable)] {
        chat.providerEnvironment
            .filter { _, value in
                guard !value.advanced else { return false }
                return value.provider == selectedProvider
                    || value.provider?.lowercased() == selectedProvider.lowercased()
            }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("配置模型服务").font(.title2.bold())
                    Text("凭据通过 Hermes 配置 API 保存，不进入 Chat transcript。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") {
                    credentialValue = ""
                    chat.cancelProviderConfiguration()
                    dismiss()
                }
                .accessibilityIdentifier("mac.provider.cancel")
            }
            .padding(20)

            Divider()

            Form {
                Section("Provider 与模型") {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("请选择").tag("")
                        ForEach(providers) { provider in
                            Text(provider.name).tag(provider.slug)
                        }
                    }
                    .onChange(of: selectedProvider) { _, value in
                        selectedModel = providers.first(where: { $0.slug == value })?.models.first ?? ""
                        selectedCredentialKey = credentialKeys.first?.key ?? ""
                        credentialValue = ""
                    }
                    Picker("模型", selection: $selectedModel) {
                        Text("请选择").tag("")
                        ForEach(selectedProviderOption?.models ?? [], id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                if !credentialKeys.isEmpty {
                    Section("凭据") {
                        Picker("配置项", selection: $selectedCredentialKey) {
                            ForEach(credentialKeys, id: \.key) { item in
                                Text(item.value.providerLabel ?? item.key).tag(item.key)
                            }
                        }
                        SecureField("输入凭据", text: $credentialValue)
                            .accessibilityIdentifier("mac.provider.credential")
                        if let selected = chat.providerEnvironment[selectedCredentialKey] {
                            Text(selected.description).font(.caption).foregroundStyle(.secondary)
                            if selected.isSet { Label("本地已配置", systemImage: "checkmark.shield.fill").foregroundStyle(HermesChatPalette.green) }
                        }
                        Button("验证凭据") {
                            Task {
                                guard !selectedCredentialKey.isEmpty, !credentialValue.isEmpty else { return }
                                let result = await chat.validateProviderCredential(
                                    key: selectedCredentialKey,
                                    value: credentialValue
                                )
                                validationMessage = result?.message ?? chat.providerSetupError ?? "验证未返回结果"
                            }
                        }
                        .disabled(selectedCredentialKey.isEmpty || credentialValue.isEmpty || chat.isProviderSetupBusy)
                    }
                }

                Section("保存") {
                    Toggle("我已确认需要使用可能产生额外费用的模型", isOn: $confirmExpensiveModel)
                    Button("保存并等待明确重试") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedProvider.isEmpty || selectedModel.isEmpty || chat.isProviderSetupBusy)
                    .accessibilityIdentifier("mac.provider.save")
                    Text("保存成功后不会自动重发上一条消息；返回工作台后由你点击“重新尝试”。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if chat.isProviderSetupBusy { ProgressView("正在读取 Hermes 配置…") }
                if !validationMessage.isEmpty { Text(validationMessage).font(.caption) }
                if let error = chat.providerSetupError {
                    Text(error).font(.caption).foregroundStyle(HermesChatPalette.coral)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 650, height: 650)
        .overlay(alignment: .topLeading) {
            HermesPageMarker(identifier: "mac.provider.root", label: "Hermes Chat Provider 配置页面")
        }
        .task {
            await chat.loadProviderSetup()
            selectedProvider = chat.providerOptions?.provider
                ?? providers.first(where: { $0.isCurrent == true })?.slug
                ?? providers.first?.slug
                ?? ""
            selectedModel = chat.providerOptions?.model
                ?? providers.first(where: { $0.slug == selectedProvider })?.models.first
                ?? ""
            selectedCredentialKey = credentialKeys.first?.key ?? ""
        }
    }

    private func save() async {
        if !selectedCredentialKey.isEmpty, !credentialValue.isEmpty {
            guard await chat.saveProviderCredential(
                key: selectedCredentialKey,
                value: credentialValue
            ) else { return }
        }
        let assignment = await chat.selectMainModel(
            provider: selectedProvider,
            model: selectedModel,
            confirmExpensiveModel: confirmExpensiveModel
        )
        credentialValue = ""
        if assignment?.ok == true { dismiss() }
    }
}
