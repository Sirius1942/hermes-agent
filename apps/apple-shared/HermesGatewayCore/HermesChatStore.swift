import Combine
import Foundation

@MainActor
class HermesChatStore: ObservableObject {
    @Published var serverText = ""
    @Published var tokenText = ""
    @Published var draft = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var toolActivities: [ToolActivity] = []
    @Published private(set) var generatingToolName: String?
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var activeSessionID: String?
    @Published private(set) var activeStoredSessionID: String?
    @Published private(set) var state: GatewayConnectionState = .disconnected
    @Published private(set) var workspacePhase: ChatWorkspacePhase = .disconnected
    @Published private(set) var providerConfigurationIssue: ProviderConfigurationIssue?
    @Published private(set) var providerOptions: HermesProviderOptions?
    @Published private(set) var providerEnvironment: [String: HermesEnvironmentVariable] = [:]
    @Published private(set) var isProviderSetupBusy = false
    @Published private(set) var providerSetupError: String?
    @Published private(set) var isStreaming = false
    @Published var pendingApproval: ApprovalRequest?
    @Published private(set) var operationError: String?

    let gateway: HermesGateway

    private let source: String
    private let gatewayRequester: any HermesGatewayRequesting
    private let loadStoredToken: () -> String?
    private let saveStoredToken: (String) throws -> Void
    private let makeConfigurationService: (URL, String?) -> any HermesConfigurationServing
    private var configurationService: (any HermesConfigurationServing)?
    private var reducer = GatewayEventReducer()
    private var reducerState = ChatReducerState()
    private var workspace = ChatWorkspaceStateMachine()
    private var cancellables: Set<AnyCancellable> = []
    private var connectionGeneration = 0
    private var providerOperationGeneration = 0
    private var sessionListGeneration = 0
    private var sessionLoadGeneration = 0

    init(
        source: String,
        gateway: HermesGateway,
        loadStoredToken: @escaping () -> String? = { nil },
        saveStoredToken: @escaping (String) throws -> Void = { _ in },
        gatewayRequester: (any HermesGatewayRequesting)? = nil,
        makeConfigurationService: @escaping (URL, String?) -> any HermesConfigurationServing = {
            HermesConfigurationClient(serverURL: $0, token: $1)
        }
    ) {
        self.source = source
        self.gateway = gateway
        self.gatewayRequester = gatewayRequester ?? gateway
        self.loadStoredToken = loadStoredToken
        self.saveStoredToken = saveStoredToken
        self.makeConfigurationService = makeConfigurationService
        wireGateway()
    }

    private func wireGateway() {
        gateway.onEvent = { [weak self] event in
            Task { @MainActor in self?.applyGatewayEvent(event) }
        }
        gateway.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.state = state
                switch state {
                case .disconnected, .failed:
                    self.clearPendingPrompt()
                case .connecting, .ready:
                    break
                }
                self.workspace.apply(.connectionChanged(state))
                self.syncWorkspaceState()
            }
            .store(in: &cancellables)
    }

    func connect() async {
        connectionGeneration += 1
        providerOperationGeneration += 1
        isProviderSetupBusy = false
        let generation = connectionGeneration
        let isRecovery: Bool
        if workspacePhase == .recovering {
            isRecovery = true
        } else {
            isRecovery = false
            workspace.apply(.beginConnect)
            syncWorkspaceState()
        }
        guard let url = URL(
            string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            state = .failed("服务器地址无效")
            workspace.apply(.connectionChanged(state))
            syncWorkspaceState()
            return
        }
        do {
            let token = tokenText.isEmpty ? loadStoredToken() : tokenText
            try await gateway.connect(serverURL: url, token: token)
            guard generation == connectionGeneration else { return }
            prepareConfigurationService(serverURL: url, token: token)
            if let token, !token.isEmpty {
                try? saveStoredToken(token)
                tokenText = ""
            }
            await refreshSessions()
            guard generation == connectionGeneration else { return }
            if isRecovery {
                let resumed = await resumeActiveStoredSessionAfterReconnect()
                guard generation == connectionGeneration else { return }
                guard resumed else {
                    state = .ready
                    return
                }
            }
            state = .ready
            if isRecovery {
                workspace.apply(.recoveryCompleted)
                syncWorkspaceState()
            }
        } catch {
            guard generation == connectionGeneration else { return }
            state = .failed(error.localizedDescription)
            workspace.apply(.connectionChanged(state))
            syncWorkspaceState()
        }
    }

    func reconnect() async {
        workspace.apply(.beginRecovery)
        syncWorkspaceState()
        await connect()
    }

    func disconnect() {
        connectionGeneration += 1
        providerOperationGeneration += 1
        isProviderSetupBusy = false
        sessionListGeneration += 1
        sessionLoadGeneration += 1
        gateway.disconnect()
        configurationService = nil
        clearPendingPrompt()
        isStreaming = false
        state = .disconnected
        workspace.apply(.connectionChanged(state))
        syncWorkspaceState()
    }

    func clearOperationError() {
        operationError = nil
    }

    func clearProviderSetupError() {
        providerSetupError = nil
    }

    func providerRecoveryPresentation(
        platform: ProviderRecoveryPlatform
    ) -> ProviderRecoveryPresentation? {
        providerConfigurationIssue?.presentation(platform: platform)
    }

    func providerConfigurationSavedPresentation(
        platform: ProviderRecoveryPlatform
    ) -> ProviderConfigurationSavedPresentation? {
        guard workspacePhase == .providerConfigurationSavedAwaitingRetry else { return nil }
        return ProviderConfigurationSavedPresentation(platform: platform)
    }

    func cancelProviderConfiguration() {
        providerOperationGeneration += 1
        isProviderSetupBusy = false
        workspace.apply(.providerConfigurationCancelled)
        syncWorkspaceState()
    }

    func prepareConfigurationService(serverURL: URL, token: String?) {
        configurationService = makeConfigurationService(serverURL, token)
    }

    func loadProviderSetup(refresh: Bool = false) async {
        guard let configurationService else {
            providerSetupError = "尚未连接 Hermes 配置服务"
            return
        }
        let generation = beginProviderOperation()
        defer { finishProviderOperation(generation) }
        do {
            async let options = configurationService.providerOptions(
                includeUnconfigured: true,
                refresh: refresh
            )
            async let environment = configurationService.environment()
            let loadedOptions = try await options
            let loadedEnvironment = try await environment
            guard generation == providerOperationGeneration else { return }
            providerOptions = loadedOptions
            providerEnvironment = loadedEnvironment
            providerSetupError = nil
        } catch {
            guard generation == providerOperationGeneration else { return }
            providerSetupError = error.localizedDescription
        }
    }

    func validateProviderCredential(
        key: String,
        value: String,
        apiKey: String? = nil
    ) async -> HermesCredentialValidation? {
        guard let configurationService else {
            providerSetupError = "尚未连接 Hermes 配置服务"
            return nil
        }
        let generation = beginProviderOperation()
        defer { finishProviderOperation(generation) }
        do {
            let result = try await configurationService.validateCredential(
                key: key,
                value: value,
                apiKey: apiKey
            )
            guard generation == providerOperationGeneration else { return nil }
            providerSetupError = result.ok || !result.reachable ? nil : result.message
            return result
        } catch {
            guard generation == providerOperationGeneration else { return nil }
            providerSetupError = error.localizedDescription
            return nil
        }
    }

    func saveProviderCredential(key: String, value: String) async -> Bool {
        guard let configurationService else {
            providerSetupError = "尚未连接 Hermes 配置服务"
            return false
        }
        let generation = beginProviderOperation()
        defer { finishProviderOperation(generation) }
        do {
            try await configurationService.saveCredential(key: key, value: value)
            guard generation == providerOperationGeneration else { return false }
            providerSetupError = nil
            return true
        } catch {
            guard generation == providerOperationGeneration else { return false }
            providerSetupError = error.localizedDescription
            return false
        }
    }

    func selectMainModel(
        provider: String,
        model: String,
        confirmExpensiveModel: Bool = false,
        baseURL: String = "",
        apiKey: String = ""
    ) async -> HermesModelAssignment? {
        guard let configurationService else {
            providerSetupError = "尚未连接 Hermes 配置服务"
            return nil
        }
        let generation = beginProviderOperation()
        defer { finishProviderOperation(generation) }
        do {
            let assignment = try await configurationService.setMainModel(
                provider: provider,
                model: model,
                confirmExpensiveModel: confirmExpensiveModel,
                baseURL: baseURL,
                apiKey: apiKey
            )
            guard generation == providerOperationGeneration else { return nil }
            if assignment.ok {
                workspace.apply(.providerConfigurationSaved)
                syncWorkspaceState()
                providerSetupError = nil
            } else if assignment.confirmRequired {
                providerSetupError = assignment.confirmMessage
            }
            return assignment
        } catch {
            guard generation == providerOperationGeneration else { return nil }
            providerSetupError = error.localizedDescription
            return nil
        }
    }

    func retryProviderRequest() async {
        guard workspacePhase == .providerConfigurationSavedAwaitingRetry else { return }
        guard let sessionID = activeSessionID else {
            providerSetupError = "没有可重试的 Hermes 会话"
            return
        }
        let generation = sessionLoadGeneration
        do {
            let result = try await gatewayRequester.request(
                method: "slash.exec",
                params: .object([
                    "session_id": .string(sessionID),
                    "command": .string("/retry"),
                ])
            )
            guard isCurrentSessionOperation(sessionID, generation: generation) else { return }
            guard result.objectValue?["type"]?.stringValue == "send",
                  let rawMessage = result.objectValue?["message"]?.stringValue
            else {
                throw GatewayError(code: nil, message: "Hermes 未返回可重试的上一条消息")
            }
            let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw GatewayError(code: nil, message: "Hermes 未返回可重试的上一条消息")
            }

            truncateLastFailedExchangeForRetry()
            workspace.apply(.providerRetryRequested)
            syncWorkspaceState()
            providerSetupError = nil
            await submit(message, sessionID: sessionID)
        } catch {
            guard isCurrentSessionOperation(sessionID, generation: generation) else { return }
            providerSetupError = error.localizedDescription
        }
    }

    func refreshSessions() async {
        let connection = connectionGeneration
        sessionListGeneration += 1
        let listGeneration = sessionListGeneration
        do {
            let result = try await gatewayRequester.request(
                method: "session.list",
                params: .object(["limit": .number(30)])
            )
            guard connection == connectionGeneration,
                  listGeneration == sessionListGeneration
            else {
                return
            }
            sessions = Self.sessions(from: result)
            operationError = nil
        } catch {
            guard connection == connectionGeneration,
                  listGeneration == sessionListGeneration
            else {
                return
            }
            operationError = error.localizedDescription
        }
    }

    @discardableResult
    func createSession() async -> String? {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        workspace.apply(.beginSessionLoad)
        syncWorkspaceState()
        do {
            let result = try await gatewayRequester.request(
                method: "session.create",
                params: .object(["source": .string(source)])
            )
            if generation != sessionLoadGeneration {
                if let staleLiveSessionID = result.objectValue?["session_id"]?.stringValue {
                    await closeStaleLiveSession(staleLiveSessionID)
                }
                return nil
            }
            guard let id = result.objectValue?["session_id"]?.stringValue else {
                throw GatewayError(code: nil, message: "Hermes 创建会话时未返回 live session_id")
            }
            let history = GatewayHistoryDecoder.decode(result)
            activateSession(
                id,
                storedSessionID: result.objectValue?["stored_session_id"]?.stringValue,
                history: history
            )
            operationError = nil
            workspace.apply(.sessionLoadCompleted)
            syncWorkspaceState()
            return id
        } catch {
            guard generation == sessionLoadGeneration else { return nil }
            operationError = error.localizedDescription
            workspace.apply(.sessionLoadFailed)
            syncWorkspaceState()
            return nil
        }
    }

    @discardableResult
    func selectSession(_ storedSessionID: String) async -> Bool {
        sessionLoadGeneration += 1
        let generation = sessionLoadGeneration
        workspace.apply(.beginSessionLoad)
        syncWorkspaceState()
        do {
            let result = try await gatewayRequester.request(
                method: "session.resume",
                params: .object(["session_id": .string(storedSessionID)])
            )
            if generation != sessionLoadGeneration {
                if let staleLiveSessionID = result.objectValue?["session_id"]?.stringValue {
                    await closeStaleLiveSession(staleLiveSessionID)
                }
                return false
            }
            guard let liveSessionID = result.objectValue?["session_id"]?.stringValue else {
                throw GatewayError(code: nil, message: "Hermes 恢复会话时未返回 live session_id")
            }
            let history = GatewayHistoryDecoder.decode(result)
            activateSession(
                liveSessionID,
                storedSessionID: result.objectValue?["resumed"]?.stringValue ?? storedSessionID,
                history: history
            )
            operationError = nil
            workspace.apply(.sessionLoadCompleted)
            syncWorkspaceState()
            return true
        } catch {
            guard generation == sessionLoadGeneration else { return false }
            operationError = error.localizedDescription
            workspace.apply(.sessionLoadFailed)
            syncWorkspaceState()
            return false
        }
    }

    @discardableResult
    func resumeActiveStoredSessionAfterReconnect() async -> Bool {
        guard let activeStoredSessionID else { return true }
        return await selectSession(activeStoredSessionID)
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, state == .ready else { return }
        guard let sessionID = activeSessionID else {
            guard let sessionID = await createSession() else { return }
            await submit(text, sessionID: sessionID)
            return
        }
        await submit(text, sessionID: sessionID)
    }

    func stop() async {
        guard let sessionID = activeSessionID else { return }
        let generation = sessionLoadGeneration
        workspace.apply(.beginStop)
        syncWorkspaceState()
        do {
            let result = try await gatewayRequester.request(
                method: "session.interrupt",
                params: .object(["session_id": .string(sessionID)])
            )
            guard isCurrentSessionOperation(sessionID, generation: generation) else { return }
            isStreaming = false
            operationError = nil
            if result.objectValue?["status"]?.stringValue == "interrupted" {
                reducer.interruptActiveWork(in: &reducerState)
                messages = reducerState.messages
                toolActivities = reducerState.toolActivities
                generatingToolName = reducerState.generatingToolName
                clearPendingPrompt()
                workspace.apply(.stopCompleted)
            } else {
                workspace.apply(.stopFailed)
            }
            syncWorkspaceState()
        } catch {
            guard isCurrentSessionOperation(sessionID, generation: generation) else { return }
            operationError = error.localizedDescription
            workspace.apply(.stopFailed)
            syncWorkspaceState()
        }
    }

    func respond(to request: ApprovalRequest, accepted: Bool, value: String? = nil) async {
        guard let sessionID = request.sessionID ?? activeSessionID else { return }
        let generation = sessionLoadGeneration
        let response = GatewayPromptResponse(request: request, accepted: accepted, value: value)
        do {
            _ = try await gatewayRequester.request(method: response.method, params: response.params)
            guard isCurrentSessionOperation(sessionID, generation: generation),
                  reducerState.pendingApproval == request
            else {
                return
            }
            operationError = nil
            if clearPendingPrompt(matching: request) {
                workspace.apply(.promptResponded)
                syncWorkspaceState()
            }
        } catch {
            guard isCurrentSessionOperation(sessionID, generation: generation),
                  reducerState.pendingApproval == request
            else {
                return
            }
            operationError = error.localizedDescription
            workspace.apply(.promptResponseFailed)
            syncWorkspaceState()
        }
    }

    private func submit(_ text: String, sessionID: String) async {
        guard activeSessionID == sessionID else { return }
        let generation = sessionLoadGeneration
        draft = ""
        isStreaming = true
        workspace.apply(.beginSubmit)
        syncWorkspaceState()
        reducerState.messages.append(
            ChatMessage(
                id: UUID().uuidString,
                role: "user",
                text: text,
                isStreaming: false,
                error: nil
            )
        )
        messages = reducerState.messages
        do {
            _ = try await gatewayRequester.request(
                method: "prompt.submit",
                params: .object([
                    "session_id": .string(sessionID),
                    "text": .string(text),
                ])
            )
        } catch {
            guard isCurrentSessionOperation(sessionID, generation: generation) else { return }
            draft = text
            isStreaming = false
            operationError = error.localizedDescription
            workspace.apply(.submitFailed(error.localizedDescription))
            syncWorkspaceState()
        }
    }

    func applyGatewayEvent(_ event: GatewayEvent) {
        if let eventSessionID = event.sessionID,
           eventSessionID != activeSessionID
        {
            return
        }
        reducer.apply(event, to: &reducerState)
        messages = reducerState.messages
        toolActivities = reducerState.toolActivities
        generatingToolName = reducerState.generatingToolName
        pendingApproval = reducerState.pendingApproval
        if event.type == "message.start" {
            isStreaming = true
            workspace.apply(.messageStarted)
        }
        if event.type == "message.complete" || event.type == "error" {
            isStreaming = false
            state = .ready
        }
        switch event.type {
        case "message.complete":
            workspace.apply(.messageCompleted)
        case "error":
            let object = event.payload?.objectValue ?? [:]
            let message = object["message"]?.stringValue
                ?? object["error"]?.stringValue
                ?? object["text"]?.stringValue
                ?? "Hermes 请求失败"
            workspace.apply(.turnFailed(message))
        case "approval.request", "clarify.request", "secret.request", "sudo.request":
            workspace.apply(.promptRequested)
        default:
            break
        }
        syncWorkspaceState()
    }

    private func activateSession(
        _ id: String,
        storedSessionID: String?,
        history: ChatHistorySnapshot
    ) {
        activeSessionID = id
        activeStoredSessionID = storedSessionID
        reducerState.activeSessionID = id
        reducerState.messages = history.messages
        reducerState.toolActivities = history.toolActivities
        reducerState.generatingToolName = nil
        reducerState.currentStreamingMessageID = nil
        reducerState.pendingApproval = nil
        reducerState.seenEventKeys.removeAll()
        messages = history.messages
        toolActivities = history.toolActivities
        generatingToolName = nil
        pendingApproval = nil
        isStreaming = false
    }

    private func truncateLastFailedExchangeForRetry() {
        guard let lastUserIndex = reducerState.messages.lastIndex(where: { $0.role == "user" })
        else { return }
        reducerState.messages.removeSubrange(lastUserIndex...)
        reducerState.currentStreamingMessageID = nil
        reducerState.generatingToolName = nil
        messages = reducerState.messages
        generatingToolName = nil
    }

    private func syncWorkspaceState() {
        workspacePhase = workspace.phase
        providerConfigurationIssue = workspace.providerConfigurationIssue
    }

    private func beginProviderOperation() -> Int {
        providerOperationGeneration += 1
        isProviderSetupBusy = true
        return providerOperationGeneration
    }

    private func finishProviderOperation(_ generation: Int) {
        guard generation == providerOperationGeneration else { return }
        isProviderSetupBusy = false
    }

    private func clearPendingPrompt() {
        reducerState.pendingApproval = nil
        pendingApproval = nil
    }

    private func closeStaleLiveSession(_ sessionID: String) async {
        _ = try? await gatewayRequester.request(
            method: "session.close",
            params: .object(["session_id": .string(sessionID)])
        )
    }

    private func isCurrentSessionOperation(_ sessionID: String, generation: Int) -> Bool {
        generation == sessionLoadGeneration && activeSessionID == sessionID
    }

    @discardableResult
    private func clearPendingPrompt(matching request: ApprovalRequest) -> Bool {
        guard reducerState.pendingApproval == request else { return false }
        clearPendingPrompt()
        return true
    }

    private static func sessions(from value: JSONValue) -> [ChatSession] {
        guard let rows = value.objectValue?["sessions"]?.arrayValue else { return [] }
        return rows.compactMap { row in
            guard let object = row.objectValue,
                  let id = object["id"]?.stringValue
            else { return nil }
            let title = object["title"]?.stringValue
            return ChatSession(
                id: id,
                title: title?.isEmpty == false ? title! : "未命名会话",
                preview: object["preview"]?.stringValue ?? ""
            )
        }
    }

}
