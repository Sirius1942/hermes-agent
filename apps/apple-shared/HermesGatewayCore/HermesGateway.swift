import Combine
import CryptoKit
import Foundation

enum GatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)
}

@MainActor
protocol HermesGatewayRequesting: AnyObject {
    func request(method: String, params: JSONValue?) async throws -> JSONValue
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

struct GatewayEvent: Codable, Equatable {
    let type: String
    let sessionID: String?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case payload
    }
}

struct GatewayError: Codable, LocalizedError, Equatable {
    let code: Int?
    let message: String?

    var errorDescription: String? {
        message ?? "Hermes 网关请求失败"
    }
}

enum EvidenceIdentifier {
    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// 可交给 TestLoop 的脱敏 RPC/事件轨迹。
///
/// 轨迹只保留方法名、事件类型、字段名、结果类别和 ID 哈希，不保留 token、密码、
/// prompt 正文、工具输出或 provider 原始诊断。这样既能证明真实协议路径，又不会把
/// 用户秘密或完整对话内容写入验收证据。
struct GatewayTraceRecord: Codable, Equatable {
    let sequence: Int
    let timestamp: String
    let direction: String
    let idHash: String?
    let method: String?
    let eventType: String?
    let sessionIDHash: String?
    let outcome: String
    let fieldNames: [String]
    let errorCode: Int?

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case direction
        case idHash = "id_hash"
        case method
        case eventType = "event_type"
        case sessionIDHash = "session_id_hash"
        case outcome
        case fieldNames = "field_names"
        case errorCode = "error_code"
    }
}

struct GatewayTraceExport: Codable, Equatable {
    let schemaVersion: String
    let runID: String
    let releaseID: String
    let buildID: String
    let platform: String
    let pageID: String
    let scenarioID: String
    let sessionIDHash: String?
    let events: [GatewayTraceRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID = "run_id"
        case releaseID = "release_id"
        case buildID = "build_id"
        case platform
        case pageID = "page_id"
        case scenarioID = "scenario_id"
        case sessionIDHash = "session_id_hash"
        case events
    }
}

private struct GatewayTraceMirror: Codable {
    let schemaVersion: String
    let events: [GatewayTraceRecord]
}

@MainActor
final class HermesGatewayTraceRecorder {
    private(set) var records: [GatewayTraceRecord] = []
    private var nextSequence = 0
    private let clock: () -> Date
    private let mirrorURL: URL?

    init(clock: @escaping () -> Date = Date.init, mirrorURL: URL? = nil) {
        self.clock = clock
        self.mirrorURL = mirrorURL
    }

    func recordRequest(id: String, method: String, params: JSONValue?) {
        append(
            direction: "request",
            id: id,
            method: method,
            eventType: nil,
            sessionID: sessionID(from: params),
            outcome: "sent",
            fields: fields(from: params),
            errorCode: nil
        )
    }

    func recordResponse(
        id: String,
        method: String,
        result: JSONValue?,
        error: GatewayError? = nil
    ) {
        append(
            direction: "response",
            id: id,
            method: method,
            eventType: nil,
            sessionID: sessionID(from: result),
            outcome: error == nil ? "success" : "error",
            fields: fields(from: result),
            errorCode: error?.code
        )
    }

    func recordEvent(type: String, sessionID: String?, payload: JSONValue?) {
        append(
            direction: "event",
            id: nil,
            method: "event",
            eventType: type,
            sessionID: sessionID,
            outcome: "received",
            fields: fields(from: payload),
            errorCode: nil
        )
    }

    func recordLifecycle(_ outcome: String, error: GatewayError? = nil) {
        append(
            direction: "lifecycle",
            id: nil,
            method: nil,
            eventType: nil,
            sessionID: nil,
            outcome: outcome,
            fields: [],
            errorCode: error?.code
        )
    }

    func export(
        runID: String,
        releaseID: String,
        buildID: String,
        platform: String,
        pageID: String,
        scenarioID: String,
        sessionID: String?
    ) -> GatewayTraceExport {
        GatewayTraceExport(
            schemaVersion: "1",
            runID: runID,
            releaseID: releaseID,
            buildID: buildID,
            platform: platform,
            pageID: pageID,
            scenarioID: scenarioID,
            sessionIDHash: Self.hash(sessionID),
            events: records
        )
    }

    func reset() {
        records.removeAll(keepingCapacity: true)
        nextSequence = 0
        persistMirror()
    }

    func write(_ export: GatewayTraceExport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(export)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func append(
        direction: String,
        id: String?,
        method: String?,
        eventType: String?,
        sessionID: String?,
        outcome: String,
        fields: [String],
        errorCode: Int?
    ) {
        nextSequence += 1
        let formatter = ISO8601DateFormatter()
        records.append(
            GatewayTraceRecord(
                sequence: nextSequence,
                timestamp: formatter.string(from: clock()),
                direction: direction,
                idHash: Self.hash(id),
                method: method,
                eventType: eventType,
                sessionIDHash: Self.hash(sessionID),
                outcome: outcome,
                fieldNames: fields,
                errorCode: errorCode
            )
        )
        persistMirror()
    }

    private func fields(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if let object = value.objectValue { return object.keys.sorted() }
        if value.arrayValue != nil { return ["<array>"] }
        return ["<scalar>"]
    }

    private func sessionID(from value: JSONValue?) -> String? {
        guard let object = value?.objectValue else { return nil }
        return object["session_id"]?.stringValue
            ?? object["stored_session_id"]?.stringValue
            ?? object["resumed"]?.stringValue
    }

    private static func hash(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return EvidenceIdentifier.sha256(value)
    }

    private func persistMirror() {
        guard let mirrorURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(
            GatewayTraceMirror(schemaVersion: "1", events: records)
        ) else { return }
        try? FileManager.default.createDirectory(
            at: mirrorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: mirrorURL, options: .atomic)
    }
}

enum GatewayURL {
    static func websocketURL(serverURL: URL, token: String? = nil, ticket: String? = nil) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)/api/ws".replacingOccurrences(of: "//", with: "/")

        var query = components.queryItems ?? []
        query.removeAll { $0.name == "token" || $0.name == "ticket" }
        if let token, !token.isEmpty {
            query.append(URLQueryItem(name: "token", value: token))
        } else if let ticket, !ticket.isEmpty {
            query.append(URLQueryItem(name: "ticket", value: ticket))
        }
        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "/"))
            components.percentEncodedQuery = query.map { item in
                let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let rawValue = item.value ?? ""
                let value = rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawValue
                return "\(name)=\(value)"
            }.joined(separator: "&")
        }
        return components.url
    }
}

@MainActor
final class HermesGateway: NSObject, ObservableObject, @preconcurrency URLSessionWebSocketDelegate {
    @Published private(set) var state: GatewayConnectionState = .disconnected

    var onEvent: ((GatewayEvent) -> Void)?
    let traceRecorder: HermesGatewayTraceRecorder

    private let requestIDPrefix: String
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var nextID = 0
    private var pending: [String: PendingRequest] = [:]
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var openTimeoutTask: Task<Void, Never>?
    private var connectionGeneration = 0

    init(clientID: String = "apple") {
        let sanitized = clientID
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        requestIDPrefix = sanitized.isEmpty ? "apple" : sanitized
        #if DEBUG
        let mirrorURL = ProcessInfo.processInfo.environment["HERMES_APPLE_EVIDENCE_RPC_TRACE_PATH"]
            .flatMap { value in value.isEmpty ? nil : URL(fileURLWithPath: value) }
        #else
        let mirrorURL: URL? = nil
        #endif
        traceRecorder = HermesGatewayTraceRecorder(mirrorURL: mirrorURL)
        super.init()
    }

    func connect(
        serverURL: URL,
        token: String?,
        ticket: String? = nil,
        timeout: Duration = .seconds(15)
    ) async throws {
        disconnect()
        let generation = connectionGeneration
        guard let url = GatewayURL.websocketURL(serverURL: serverURL, token: token, ticket: ticket) else {
            traceRecorder.recordLifecycle("invalid_url")
            throw GatewayError(code: nil, message: "服务器地址无效")
        }

        state = .connecting
        traceRecorder.recordLifecycle("connecting")
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url)
        self.socket = socket

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                openContinuation = continuation
                openTimeoutTask = Task { [weak self, weak socket] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    guard let self, let socket,
                          generation == self.connectionGeneration,
                          socket === self.socket
                    else {
                        return
                    }
                    self.failConnection(GatewayError(code: nil, message: "连接 Hermes 超时"))
                }
                socket.resume()
            }
            guard generation == connectionGeneration, socket === self.socket else {
                throw GatewayError(code: nil, message: "连接已失效")
            }
            state = .ready
            traceRecorder.recordLifecycle("ready")
            receiveNext()
        } catch {
            if generation == connectionGeneration,
               socket === self.socket,
               case .connecting = state
            {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func disconnect() {
        connectionGeneration += 1
        let socket = self.socket
        let session = self.session
        self.socket = nil
        self.session = nil
        state = .disconnected
        traceRecorder.recordLifecycle("disconnected")
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume(throwing: GatewayError(code: nil, message: "连接已关闭"))
        openContinuation = nil
        rejectPending(with: GatewayError(code: nil, message: "连接已关闭"))
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard state == .ready, let socket else {
            throw GatewayError(code: nil, message: "尚未连接 Hermes")
        }
        nextID += 1
        let id = "\(requestIDPrefix)-\(nextID)"
        let frame = OutgoingFrame(jsonrpc: "2.0", id: id, method: method, params: params)
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayError(code: nil, message: "无法编码 Hermes 请求")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = PendingRequest(method: method, continuation: continuation)
            traceRecorder.recordRequest(id: id, method: method, params: params)
            Task { @MainActor [weak self, weak socket] in
                guard let self, let socket else {
                    guard let pending = self?.pending.removeValue(forKey: id) else { return }
                    pending.continuation.resume(
                        throwing: GatewayError(code: nil, message: "连接已关闭")
                    )
                    return
                }
                do {
                    try await socket.send(.string(text))
                } catch {
                    guard let pending = self.pending.removeValue(forKey: id) else { return }
                    let gatewayError = GatewayError(code: nil, message: error.localizedDescription)
                    self.traceRecorder.recordResponse(
                        id: id,
                        method: pending.method,
                        result: nil,
                        error: gatewayError
                    )
                    pending.continuation.resume(throwing: error)
                }
            }
        }
    }

    private func receiveNext() {
        guard let socket else { return }
        socket.receive { [weak self, weak socket] result in
            Task { @MainActor in
                guard let self, let socket, socket === self.socket else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if self.socket != nil { self.receiveNext() }
                case .failure(let error):
                    self.failConnection(error)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let frame = try? JSONDecoder().decode(IncomingFrame.self, from: data) else { return }
        if let id = frame.id, let pendingRequest = pending.removeValue(forKey: id) {
            if let error = frame.error {
                traceRecorder.recordResponse(
                    id: id,
                    method: pendingRequest.method,
                    result: nil,
                    error: error
                )
                pendingRequest.continuation.resume(throwing: error)
            } else {
                traceRecorder.recordResponse(
                    id: id,
                    method: pendingRequest.method,
                    result: frame.result,
                    error: nil
                )
                pendingRequest.continuation.resume(returning: frame.result ?? .null)
            }
            return
        }
        guard frame.method == "event",
              let params = frame.params?.objectValue,
              let type = params["type"]?.stringValue
        else { return }
        traceRecorder.recordEvent(
            type: type,
            sessionID: params["session_id"]?.stringValue,
            payload: params["payload"]
        )
        onEvent?(
            GatewayEvent(
                type: type,
                sessionID: params["session_id"]?.stringValue,
                payload: params["payload"]
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === socket else { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        openContinuation?.resume()
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            guard let self, let socket = self.socket, task === socket else { return }
            self.failConnection(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === socket else { return }
        guard state != .disconnected else { return }
        failConnection(
            GatewayError(code: nil, message: "WebSocket 已断开（\(closeCode.rawValue)）")
        )
    }

    private func failConnection(_ error: Error) {
        guard state != .disconnected else { return }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        if let continuation = openContinuation {
            openContinuation = nil
            continuation.resume(throwing: error)
        }
        rejectPending(with: error)
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        state = .failed(error.localizedDescription)
        traceRecorder.recordLifecycle(
            "failed",
            error: error as? GatewayError ?? GatewayError(code: nil, message: error.localizedDescription)
        )
    }

    private func rejectPending(with error: Error) {
        let requests = pending
        pending.removeAll()
        for (id, request) in requests {
            let gatewayError = error as? GatewayError
                ?? GatewayError(code: nil, message: error.localizedDescription)
            traceRecorder.recordResponse(
                id: id,
                method: request.method,
                result: nil,
                error: gatewayError
            )
            request.continuation.resume(throwing: error)
        }
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }
}

extension HermesGateway: HermesGatewayRequesting {}

private struct OutgoingFrame: Codable {
    let jsonrpc: String
    let id: String
    let method: String
    let params: JSONValue?
}

private struct IncomingFrame: Codable {
    let id: String?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: GatewayError?
}
