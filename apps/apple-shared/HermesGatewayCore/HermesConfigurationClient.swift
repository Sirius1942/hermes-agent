import Foundation

protocol HermesConfigurationServing: AnyObject {
    func providerOptions(includeUnconfigured: Bool, refresh: Bool) async throws
        -> HermesProviderOptions
    func environment() async throws -> [String: HermesEnvironmentVariable]
    func validateCredential(key: String, value: String, apiKey: String?) async throws
        -> HermesCredentialValidation
    func saveCredential(key: String, value: String) async throws
    func setMainModel(
        provider: String,
        model: String,
        confirmExpensiveModel: Bool,
        baseURL: String,
        apiKey: String
    ) async throws -> HermesModelAssignment
}

struct HermesProviderOption: Codable, Equatable, Identifiable {
    let name: String
    let slug: String
    let models: [String]
    let isCurrent: Bool?
    let authenticated: Bool?
    let warning: String?

    var id: String { slug }

    private enum CodingKeys: String, CodingKey {
        case name
        case slug
        case models
        case isCurrent = "is_current"
        case authenticated
        case warning
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try container.decode(String.self, forKey: .slug)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        isCurrent = try container.decodeIfPresent(Bool.self, forKey: .isCurrent)
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated)
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
    }
}

struct HermesProviderOptions: Codable, Equatable {
    let model: String?
    let provider: String?
    let providers: [HermesProviderOption]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        providers = try container.decodeIfPresent([HermesProviderOption].self, forKey: .providers) ?? []
    }
}

struct HermesEnvironmentVariable: Codable, Equatable {
    let isSet: Bool
    let redactedValue: String?
    let description: String
    let url: String?
    let category: String
    let isPassword: Bool
    let advanced: Bool
    let provider: String?
    let providerLabel: String?

    private enum CodingKeys: String, CodingKey {
        case isSet = "is_set"
        case redactedValue = "redacted_value"
        case description
        case url
        case category
        case isPassword = "is_password"
        case advanced
        case provider
        case providerLabel = "provider_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSet = try container.decodeIfPresent(Bool.self, forKey: .isSet) ?? false
        redactedValue = try container.decodeIfPresent(String.self, forKey: .redactedValue)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        isPassword = try container.decodeIfPresent(Bool.self, forKey: .isPassword) ?? false
        advanced = try container.decodeIfPresent(Bool.self, forKey: .advanced) ?? false
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel)
    }
}

struct HermesCredentialValidation: Codable, Equatable {
    let ok: Bool
    let reachable: Bool
    let message: String
    let models: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
    }
}

struct HermesModelAssignment: Codable, Equatable {
    let ok: Bool
    let provider: String?
    let model: String?
    let confirmRequired: Bool
    let confirmMessage: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case provider
        case model
        case confirmRequired = "confirm_required"
        case confirmMessage = "confirm_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        confirmRequired = try container.decodeIfPresent(Bool.self, forKey: .confirmRequired) ?? false
        confirmMessage = try container.decodeIfPresent(String.self, forKey: .confirmMessage)
    }
}

enum HermesConfigurationError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidResponse
    case http(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Hermes 服务器地址无效"
        case .invalidResponse:
            return "Hermes 配置服务返回了无法识别的数据"
        case .http(let status, let detail):
            return detail.isEmpty ? "Hermes 配置请求失败（HTTP \(status)）" : detail
        }
    }
}

final class HermesConfigurationClient: HermesConfigurationServing, @unchecked Sendable {
    private let serverURL: URL
    private let token: String?
    private let profile: String?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        serverURL: URL,
        token: String?,
        profile: String? = nil,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.token = token
        self.profile = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func providerOptions(includeUnconfigured: Bool = true, refresh: Bool = false) async throws
        -> HermesProviderOptions
    {
        var query = [URLQueryItem(name: "include_unconfigured", value: includeUnconfigured ? "1" : "0")]
        if refresh { query.append(URLQueryItem(name: "refresh", value: "1")) }
        let request = try makeRequest(path: "/api/model/options", query: query)
        return try await perform(request, as: HermesProviderOptions.self)
    }

    func environment() async throws -> [String: HermesEnvironmentVariable] {
        let request = try makeRequest(path: "/api/env")
        return try await perform(request, as: [String: HermesEnvironmentVariable].self)
    }

    func validateCredential(key: String, value: String, apiKey: String? = nil) async throws
        -> HermesCredentialValidation
    {
        let body = CredentialBody(key: key, value: value, apiKey: apiKey, profile: profile)
        var request = try makeRequest(path: "/api/providers/validate", method: "POST")
        request.httpBody = try encoder.encode(body)
        return try await perform(request, as: HermesCredentialValidation.self)
    }

    func saveCredential(key: String, value: String) async throws {
        let body = CredentialBody(key: key, value: value, apiKey: nil, profile: profile)
        var request = try makeRequest(path: "/api/env", method: "PUT")
        request.httpBody = try encoder.encode(body)
        _ = try await perform(request, as: MutationResponse.self)
    }

    func setMainModel(
        provider: String,
        model: String,
        confirmExpensiveModel: Bool = false,
        baseURL: String = "",
        apiKey: String = ""
    ) async throws -> HermesModelAssignment {
        let body = ModelAssignmentBody(
            scope: "main",
            provider: provider,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            confirmExpensiveModel: confirmExpensiveModel,
            profile: profile
        )
        var request = try makeRequest(path: "/api/model/set", method: "POST")
        request.httpBody = try encoder.encode(body)
        return try await perform(request, as: HermesModelAssignment.self)
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw HermesConfigurationError.invalidServerURL
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = "\(basePath)\(path)".replacingOccurrences(of: "//", with: "/")
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: query)
        if let profile, !profile.isEmpty, !queryItems.contains(where: { $0.name == "profile" }) {
            queryItems.append(URLQueryItem(name: "profile", value: profile))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw HermesConfigurationError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        return request
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesConfigurationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            throw HermesConfigurationError.http(
                status: http.statusCode,
                detail: envelope?.detail ?? envelope?.error ?? ""
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw HermesConfigurationError.invalidResponse
        }
    }
}

private struct CredentialBody: Encodable {
    let key: String
    let value: String
    let apiKey: String?
    let profile: String?

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case apiKey = "api_key"
        case profile
    }
}

private struct ModelAssignmentBody: Encodable {
    let scope: String
    let provider: String
    let model: String
    let baseURL: String
    let apiKey: String
    let confirmExpensiveModel: Bool
    let profile: String?

    private enum CodingKeys: String, CodingKey {
        case scope
        case provider
        case model
        case baseURL = "base_url"
        case apiKey = "api_key"
        case confirmExpensiveModel = "confirm_expensive_model"
        case profile
    }
}

private struct MutationResponse: Decodable {
    let ok: Bool
}

private struct ErrorEnvelope: Decodable {
    let detail: String?
    let error: String?
}
