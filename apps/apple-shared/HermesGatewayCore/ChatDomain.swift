import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    var isStreaming: Bool
    var error: String?
}

struct ChatSession: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
}

struct ProviderConfigurationIssue: Equatable {
    let summary: String
    let diagnostic: String

    func presentation(platform: ProviderRecoveryPlatform) -> ProviderRecoveryPresentation {
        ProviderRecoveryPresentation(
            platform: platform,
            title: "模型服务尚未配置",
            summary: summary,
            diagnostic: diagnostic,
            configureActionTitle: "配置服务",
            diagnosticsActionTitle: "原始诊断",
            cancelActionTitle: "取消",
            diagnosticsInitiallyExpanded: false,
            allowsAutomaticRetry: false
        )
    }
}

enum ProviderRecoveryPlatform: String, Equatable {
    case iOS = "ios"
    case macOS = "mac"
}

enum ProviderRecoveryAction: String, CaseIterable, Equatable {
    case configure
    case diagnostics
    case cancel
    case retry
}

struct ProviderRecoveryPresentation: Equatable {
    let platform: ProviderRecoveryPlatform
    let title: String
    let summary: String
    let diagnostic: String
    let configureActionTitle: String
    let diagnosticsActionTitle: String
    let cancelActionTitle: String
    let diagnosticsInitiallyExpanded: Bool
    let allowsAutomaticRetry: Bool

    func accessibilityIdentifier(for action: ProviderRecoveryAction) -> String {
        "\(platform.rawValue).provider.\(action.rawValue)"
    }
}

struct ProviderConfigurationSavedPresentation: Equatable {
    let platform: ProviderRecoveryPlatform
    let title = "模型服务已保存"
    let summary = "配置已经保存。为避免重复发送上一条消息，需要你明确重新尝试。"
    let cancelActionTitle = "稍后重试"
    let retryActionTitle = "重新尝试"
    let allowsAutomaticRetry = false

    func accessibilityIdentifier(for action: ProviderRecoveryAction) -> String {
        "\(platform.rawValue).provider.\(action.rawValue)"
    }
}

enum ProviderDiagnosticSanitizer {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{6,}"#, "$1 [已隐藏]"),
        (#"(?i)\bsk-[A-Za-z0-9_-]{6,}\b"#, "[已隐藏的 API Key]"),
        (
            #"(?i)\b((?:[A-Z][A-Z0-9_]*(?:API_KEY|TOKEN|SECRET|PASSWORD)|api[_-]?key|token|secret|password))\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            "$1=[已隐藏]"
        ),
    ]

    static func sanitize(_ diagnostic: String) -> String {
        replacements.reduce(diagnostic) { value, replacement in
            guard let expression = try? NSRegularExpression(
                pattern: replacement.pattern,
                options: []
            ) else {
                return value
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }
    }
}

enum ProviderSetupErrorClassifier {
    private static let markers = [
        "no inference provider configured",
        "no inference provider is configured",
        "no hermes provider is configured",
        "no llm provider configured",
        "openrouter_api_key",
        "openai_api_key",
        "anthropic_api_key",
        "set an api key",
        "no_provider_configured",
    ]

    static func classify(_ message: String) -> ProviderConfigurationIssue? {
        let normalized = message.lowercased()
        guard markers.contains(where: normalized.contains) else { return nil }
        return ProviderConfigurationIssue(
            summary: "尚未配置可用的模型服务。请在 App 内配置 Provider 后明确重试。",
            diagnostic: ProviderDiagnosticSanitizer.sanitize(message)
        )
    }
}

enum ChatWorkspacePhase: Equatable {
    case disconnected
    case connecting
    case ready
    case loadingSession
    case streaming
    case stopping
    case interrupted
    case awaitingInput
    case recovering
    case configurationRequired
    case providerConfigurationSavedAwaitingRetry
    case failed(String)
}

enum ChatWorkspaceSignal: Equatable {
    case beginConnect
    case connectionChanged(GatewayConnectionState)
    case beginSessionLoad
    case sessionLoadCompleted
    case sessionLoadFailed
    case beginSubmit
    case submitFailed(String)
    case messageStarted
    case messageCompleted
    case turnFailed(String)
    case providerConfigurationSaved
    case providerRetryRequested
    case providerConfigurationCancelled
    case beginStop
    case stopCompleted
    case stopFailed
    case promptRequested
    case promptResponded
    case promptResponseFailed
    case beginRecovery
    case recoveryCompleted
}

struct ChatWorkspaceStateMachine: Equatable {
    private(set) var phase: ChatWorkspacePhase = .disconnected
    private(set) var providerConfigurationIssue: ProviderConfigurationIssue?

    mutating func apply(_ signal: ChatWorkspaceSignal) {
        switch signal {
        case .beginConnect:
            phase = .connecting
        case .connectionChanged(let state):
            switch state {
            case .disconnected:
                phase = .disconnected
            case .connecting:
                if phase != .recovering { phase = .connecting }
            case .ready:
                if !Self.connectionReadyMustPreserve(phase) { phase = .ready }
            case .failed(let message):
                phase = .failed(message)
            }
        case .beginSessionLoad:
            phase = .loadingSession
        case .sessionLoadCompleted:
            phase = .ready
        case .sessionLoadFailed:
            phase = .ready
        case .beginSubmit:
            providerConfigurationIssue = nil
            phase = .streaming
        case .submitFailed(let message), .turnFailed(let message):
            if let issue = ProviderSetupErrorClassifier.classify(message) {
                providerConfigurationIssue = issue
                phase = .configurationRequired
            } else {
                phase = .failed(message)
            }
        case .providerConfigurationSaved:
            providerConfigurationIssue = nil
            if phase == .configurationRequired {
                phase = .providerConfigurationSavedAwaitingRetry
            }
        case .providerRetryRequested:
            if phase == .providerConfigurationSavedAwaitingRetry {
                phase = .ready
            }
        case .providerConfigurationCancelled:
            if providerConfigurationIssue != nil { phase = .configurationRequired }
        case .messageStarted:
            phase = .streaming
        case .messageCompleted:
            phase = phase == .stopping || phase == .interrupted ? .interrupted : .ready
        case .beginStop:
            phase = .stopping
        case .stopCompleted:
            phase = .interrupted
        case .stopFailed:
            phase = .streaming
        case .promptRequested:
            phase = .awaitingInput
        case .promptResponded:
            phase = .streaming
        case .promptResponseFailed:
            phase = .awaitingInput
        case .beginRecovery:
            phase = .recovering
        case .recoveryCompleted:
            phase = .ready
        }
    }

    private static func connectionReadyMustPreserve(_ phase: ChatWorkspacePhase) -> Bool {
        switch phase {
        case .loadingSession, .streaming, .stopping, .interrupted, .awaitingInput,
             .recovering, .configurationRequired, .providerConfigurationSavedAwaitingRetry:
            return true
        case .disconnected, .connecting, .ready, .failed:
            return false
        }
    }
}

struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let kind: String
    let prompt: String
    let detail: String?
    let choices: [String]
    let sessionID: String?

    init(
        id: String,
        kind: String,
        prompt: String,
        detail: String? = nil,
        choices: [String] = [],
        sessionID: String?
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.detail = detail
        self.choices = choices
        self.sessionID = sessionID
    }
}

enum ToolActivityStatus: String, Equatable {
    case running
    case completed
    case failed
    case interrupted
}

struct ToolActivity: Identifiable, Equatable {
    let id: String
    var name: String
    var context: String
    var summary: String
    var status: ToolActivityStatus
    var durationSeconds: Double?
    var inlineDiff: String?
}

struct GatewayPromptResponse {
    let method: String
    let params: JSONValue

    init(request: ApprovalRequest, accepted: Bool, value: String?) {
        switch request.kind {
        case "approval.request":
            method = "approval.respond"
            var payload: [String: JSONValue] = [
                "choice": .string(accepted ? "once" : "deny")
            ]
            if let sessionID = request.sessionID {
                payload["session_id"] = .string(sessionID)
            }
            params = .object(payload)
        case "clarify.request":
            method = "clarify.respond"
            params = .object([
                "request_id": .string(request.id),
                "answer": .string(accepted ? (value ?? "") : ""),
            ])
        case "sudo.request":
            method = "sudo.respond"
            params = .object([
                "request_id": .string(request.id),
                "password": .string(accepted ? (value ?? "") : ""),
            ])
        default:
            method = "secret.respond"
            params = .object([
                "request_id": .string(request.id),
                "value": .string(accepted ? (value ?? "") : ""),
            ])
        }
    }
}

struct ChatReducerState: Equatable {
    var messages: [ChatMessage] = []
    var activeSessionID: String?
    var pendingApproval: ApprovalRequest?
    var seenEventKeys: Set<String> = []
    var currentStreamingMessageID: String?
    var toolActivities: [ToolActivity] = []
    var generatingToolName: String?
}

struct GatewayEventReducer {
    func interruptActiveWork(in state: inout ChatReducerState) {
        if let streamID = state.currentStreamingMessageID,
           let index = state.messages.firstIndex(where: { $0.id == streamID })
        {
            state.messages[index].isStreaming = false
        }
        for index in state.toolActivities.indices
        where state.toolActivities[index].status == .running {
            state.toolActivities[index].status = .interrupted
        }
        state.currentStreamingMessageID = nil
        state.generatingToolName = nil
        state.pendingApproval = nil
    }

    mutating func apply(_ event: GatewayEvent, to state: inout ChatReducerState) {
        if let eventSessionID = event.sessionID,
           let active = state.activeSessionID,
           eventSessionID != active
        {
            return
        }
        let object = event.payload?.objectValue ?? [:]
        let messageID = object["id"]?.stringValue ?? object["message_id"]?.stringValue
        let text = object["text"]?.stringValue
            ?? object["content"]?.stringValue
            ?? object["message"]?.stringValue
            ?? object["error"]?.stringValue
            ?? ""

        if let eventID = object["event_id"]?.stringValue {
            let eventKey = "\(event.type)|\(eventID)"
            guard state.seenEventKeys.insert(eventKey).inserted else { return }
        }

        switch event.type {
        case "message.start":
            let streamID = messageID ?? "assistant-\(UUID().uuidString)"
            state.currentStreamingMessageID = streamID
            if !state.messages.contains(where: { $0.id == streamID }) {
                state.messages.append(
                    ChatMessage(
                        id: streamID,
                        role: "assistant",
                        text: "",
                        isStreaming: true,
                        error: nil
                    )
                )
            }
        case "message.delta":
            let streamID = messageID ?? state.currentStreamingMessageID
            guard let streamID,
                  let index = state.messages.firstIndex(where: { $0.id == streamID })
            else { return }
            state.messages[index].text += text
        case "message.complete":
            state.pendingApproval = nil
            let streamID = messageID ?? state.currentStreamingMessageID
            guard let streamID,
                  let index = state.messages.firstIndex(where: { $0.id == streamID })
            else { return }
            if state.messages[index].text.isEmpty, !text.isEmpty {
                state.messages[index].text = text
            }
            state.messages[index].isStreaming = false
            state.currentStreamingMessageID = nil
            state.generatingToolName = nil
        case "error":
            let errorText = text.isEmpty ? "Hermes 请求失败" : text
            let displayError = ProviderSetupErrorClassifier.classify(errorText)?.summary ?? errorText
            let streamID = messageID ?? state.currentStreamingMessageID
            if let streamID,
               let index = state.messages.firstIndex(where: { $0.id == streamID })
            {
                state.messages[index].error = displayError
                state.messages[index].isStreaming = false
            } else if let index = state.messages.lastIndex(where: { message in
                guard message.role == "assistant", let existing = message.error else { return false }
                return existing.localizedCaseInsensitiveContains(displayError)
                    || displayError.localizedCaseInsensitiveContains(existing)
            }) {
                if displayError.count < (state.messages[index].error?.count ?? .max) {
                    state.messages[index].error = displayError
                }
            } else {
                state.messages.append(
                    ChatMessage(
                        id: messageID ?? "error-\(UUID().uuidString)",
                        role: "assistant",
                        text: "",
                        isStreaming: false,
                        error: displayError
                    )
                )
            }
            state.currentStreamingMessageID = nil
            state.generatingToolName = nil
            state.pendingApproval = nil
        case "tool.generating":
            state.generatingToolName = object["name"]?.stringValue
        case "tool.start":
            let toolID = object["tool_id"]?.stringValue ?? "tool-\(UUID().uuidString)"
            let activity = ToolActivity(
                id: toolID,
                name: object["name"]?.stringValue ?? "tool",
                context: object["context"]?.stringValue ?? object["preview"]?.stringValue ?? "",
                summary: "",
                status: .running,
                durationSeconds: nil,
                inlineDiff: nil
            )
            if let index = state.toolActivities.firstIndex(where: { $0.id == toolID }) {
                state.toolActivities[index] = activity
            } else {
                state.toolActivities.append(activity)
            }
            state.generatingToolName = nil
        case "tool.progress":
            guard let toolID = object["tool_id"]?.stringValue,
                  let index = state.toolActivities.firstIndex(where: { $0.id == toolID })
            else { return }
            state.toolActivities[index].summary = object["summary"]?.stringValue
                ?? object["preview"]?.stringValue
                ?? object["text"]?.stringValue
                ?? state.toolActivities[index].summary
        case "tool.complete":
            let toolID = object["tool_id"]?.stringValue ?? "tool-\(UUID().uuidString)"
            let failed = Self.toolResultFailed(object["result"])
            let existing = state.toolActivities.first(where: { $0.id == toolID })
            let completed = ToolActivity(
                id: toolID,
                name: object["name"]?.stringValue ?? existing?.name ?? "tool",
                context: object["context"]?.stringValue ?? existing?.context ?? "",
                summary: object["summary"]?.stringValue ?? existing?.summary ?? "",
                status: failed ? .failed : .completed,
                durationSeconds: object["duration_s"]?.numberValue,
                inlineDiff: object["inline_diff"]?.stringValue
            )
            if let index = state.toolActivities.firstIndex(where: { $0.id == toolID }) {
                state.toolActivities[index] = completed
            } else {
                state.toolActivities.append(completed)
            }
            if state.generatingToolName == completed.name {
                state.generatingToolName = nil
            }
        case "approval.request", "clarify.request", "secret.request", "sudo.request":
            let requestID = object["request_id"]?.stringValue ?? UUID().uuidString
            let prompt = object["question"]?.stringValue
                ?? object["prompt"]?.stringValue
                ?? object["description"]?.stringValue
                ?? "Hermes 需要你的响应"
            let detail: String?
            if event.type == "approval.request" {
                detail = object["command"]?.stringValue
            } else if event.type == "secret.request" {
                detail = object["env_var"]?.stringValue
            } else {
                detail = nil
            }
            let choices = object["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            state.pendingApproval = ApprovalRequest(
                id: requestID,
                kind: event.type,
                prompt: prompt,
                detail: detail,
                choices: choices,
                sessionID: event.sessionID
            )
        default:
            break
        }
    }

    private static func toolResultFailed(_ result: JSONValue?) -> Bool {
        guard let object = result?.objectValue else { return false }
        if object["success"]?.boolValue == false || object["ok"]?.boolValue == false {
            return true
        }
        if let error = object["error"]?.stringValue, !error.isEmpty {
            return true
        }
        if object["error"]?.boolValue == true {
            return true
        }
        if let status = object["status"]?.stringValue?.lowercased(),
           ["error", "failed", "blocked"].contains(status)
        {
            return true
        }
        if let exitCode = object["exit_code"]?.numberValue, exitCode != 0 {
            return true
        }
        if let returnCode = object["returncode"]?.numberValue, returnCode != 0 {
            return true
        }
        return false
    }
}

struct ChatHistorySnapshot: Equatable {
    var messages: [ChatMessage]
    var toolActivities: [ToolActivity]
}

enum GatewayHistoryDecoder {
    static func decode(_ value: JSONValue) -> ChatHistorySnapshot {
        guard let rows = value.objectValue?["messages"]?.arrayValue else {
            return ChatHistorySnapshot(messages: [], toolActivities: [])
        }
        var messages: [ChatMessage] = []
        var tools: [ToolActivity] = []
        for (index, row) in rows.enumerated() {
            guard let object = row.objectValue,
                  let role = object["role"]?.stringValue
            else { continue }
            if role == "tool" {
                tools.append(
                    ToolActivity(
                        id: object["tool_id"]?.stringValue ?? "history-tool-\(index)",
                        name: object["name"]?.stringValue ?? "tool",
                        context: object["context"]?.stringValue ?? "",
                        summary: object["summary"]?.stringValue ?? "",
                        status: .completed,
                        durationSeconds: object["duration_s"]?.numberValue,
                        inlineDiff: object["inline_diff"]?.stringValue
                    )
                )
                continue
            }
            guard role == "user" || role == "assistant" else { continue }
            let content = object["content"]?.stringValue ?? object["text"]?.stringValue ?? ""
            if content.isEmpty { continue }
            messages.append(
                ChatMessage(
                    id: object["id"]?.stringValue ?? "history-\(index)",
                    role: role,
                    text: content,
                    isStreaming: false,
                    error: nil
                )
            )
        }
        return ChatHistorySnapshot(messages: messages, toolActivities: tools)
    }
}
