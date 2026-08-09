import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Provider clients use this response-preserving seam because quota fallbacks and Retry-After need headers.
/// The repository's bounded/single-flight transport can conform directly without another network stack.
public protocol ProviderHTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> ProviderHTTPResponse
}

/// Compatibility hook for the existing body/status transport. Prefer direct `ProviderHTTPTransport`
/// conformance in the shared bounded transport so response headers remain available.
public struct HTTPTransportProviderAdapter: ProviderHTTPTransport {
    private let transport: any HTTPTransport
    public init(_ transport: any HTTPTransport) { self.transport = transport }
    public func execute(_ request: URLRequest) async throws -> ProviderHTTPResponse {
        let result = try await transport.execute(request)
        return ProviderHTTPResponse(
            statusCode: result.statusCode,
            headers: result.headers,
            body: result.data
        )
    }
}

public enum ClaudeProviderError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn, sessionExpired, tokenExpired, credentialsChanged, missingProfileScope
    case invalidOAuthURL(String), invalidResponse, connectionFailed, requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in. Run `claude` to authenticate."
        case .sessionExpired: "Session expired. Run `claude` to log in again."
        case .tokenExpired: "Token expired. Run `claude` to log in again."
        case .credentialsChanged: "Claude login changed during refresh. Refresh again."
        case .missingProfileScope: "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."
        case .invalidOAuthURL(let value): "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        case .invalidResponse: "The provider returned an invalid response."
        case .connectionFailed: "Could not connect to the provider."
        case .requestFailed(let status): "Usage request failed (HTTP \(status))."
        }
    }
}

public enum CodexProviderError: Error, LocalizedError, Equatable, Sendable {
    case notLoggedIn, sessionExpired, tokenConflict, tokenRevoked, tokenExpired, usageAPIKey
    case invalidAuthPayload, invalidResponse, connectionFailed, requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: "Not logged in. Run `codex` to authenticate."
        case .sessionExpired: "Session expired. Run `codex` to log in again."
        case .tokenConflict: "Token conflict. Run `codex` to log in again."
        case .tokenRevoked: "Token revoked. Run `codex` to log in again."
        case .tokenExpired: "Token expired. Run `codex` to log in again."
        case .usageAPIKey: "Usage not available for API key."
        case .invalidAuthPayload: "Codex auth data is invalid."
        case .invalidResponse: "The provider returned an invalid response."
        case .connectionFailed: "Could not connect to the provider."
        case .requestFailed(let status): "Usage request failed (HTTP \(status))."
        }
    }
}

public enum ResetClaimOutcome: Equatable, Sendable {
    case success, nothingToReset, noCredit, failed
}

public enum ProviderDefinitions {
    public static let claudeLinks = [
        ProviderLink(label: "Status", url: "https://status.anthropic.com/"),
        ProviderLink(label: "Dashboard", url: "https://claude.ai/settings/usage"),
    ]
    public static let codexLinks = [
        ProviderLink(label: "Status", url: "https://status.openai.com/"),
        ProviderLink(label: "Dashboard", url: "https://chatgpt.com/codex/settings/usage"),
    ]

    public static func claudeWidgets(instanceID: String) -> [WidgetDescriptor] {
        [
            ("session", "Session", "Session"), ("weekly", "Weekly", "Weekly"),
            ("sonnet", "Sonnet", "Sonnet"), ("fable", "Fable", "Fable"),
            ("extra", "Extra Usage", "Extra usage spent"), ("trend", "Usage Trend", "Usage Trend"),
            ("today", "Today", "Today"), ("yesterday", "Yesterday", "Yesterday"),
            ("last30", "Last 30 Days", "Last 30 Days"),
        ].map { WidgetDescriptor(id: "\(instanceID).\($0.0)", title: $0.1, metricLabel: $0.2) }
    }

    public static let codexWidgets: [WidgetDescriptor] = [
        ("session", "Session", "Session"), ("weekly", "Weekly", "Weekly"),
        ("spark", "Spark", "Spark"), ("sparkWeekly", "Spark Weekly", "Spark Weekly"),
        ("credits", "Extra Usage", "Credits"), ("rateLimitResets", "Rate Limit Resets", "Rate Limit Resets"),
        ("trend", "Usage Trend", "Usage Trend"), ("today", "Today", "Today"),
        ("yesterday", "Yesterday", "Yesterday"), ("last30", "Last 30 Days", "Last 30 Days"),
    ].map { WidgetDescriptor(id: "codex.\($0.0)", title: $0.1, metricLabel: $0.2) }
}

func parityNumber(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

func parityJSON(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func parityDate(_ value: Any?) -> Date? {
    if let number = parityNumber(value), number.isFinite {
        let seconds = abs(number) < 1e10 ? number : number / 1000
        return Date(timeIntervalSince1970: seconds)
    }
    guard var string = value as? String else { return nil }
    if !string.hasSuffix("Z") && !string.contains("+") { string += "Z" }
    return ISO8601DateFormatter().date(from: string)
}
